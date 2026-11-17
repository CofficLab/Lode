#!/bin/bash
# 本地升级演练：构建旧/新两个版本，本地 HTTP  serve appcast + DMG，
# 用无头 UpdateDrill 驱动旧版本完成 发现→下载→验签→安装 全链路并核对版本。
# 用法: LODE_SPARKLE_ED_KEY_FILE=<私钥文件> ./drill-update.sh [旧版本] [新版本]
# 签名身份默认取 keychain 中第一个有效代码签名身份，可用 LODE_DRILL_SIGN_IDENTITY 覆盖。
set -euo pipefail

OLD_VERSION="${1:-1.0.0}"
NEW_VERSION="${2:-1.0.1}"
KEY_FILE="${LODE_SPARKLE_ED_KEY_FILE:?set LODE_SPARKLE_ED_KEY_FILE}"
PORT="${LODE_DRILL_PORT:-8765}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lode-update-drill.XXXXXX")"
SERVER_PID=""
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sparkle-tools.sh
source "$SCRIPT_DIR/sparkle-tools.sh"
ensure_sparkle_tools

build_app() {
    local version="$1" build="$2" dest="$3"
    xcodebuild -project "$ROOT/Lode.xcodeproj" -scheme Lode -configuration Debug \
        -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
        CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation -skipMacroValidation \
        SYMROOT="$WORK/sym-$version" build > "$WORK/build-$version.log" 2>&1 \
        || { tail -20 "$WORK/build-$version.log" >&2; exit 1; }
    mkdir -p "$dest"
    ditto "$WORK/sym-$version/Debug/Lode.app" "$dest/Lode.app"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$dest/Lode.app"
}

# Sparkle requires old and new apps to share one signing identity; ad-hoc
# signatures embed per-binary cdhash requirements that can never match. Use a
# real code-signing identity from the keychain (override with
# LODE_DRILL_SIGN_IDENTITY); both drill copies are signed with it.
SIGN_IDENTITY="${LODE_DRILL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/^ *1) \([0-9A-Fa-f]*\) .*/\1/p')}"
[ -n "$SIGN_IDENTITY" ] || { echo "no valid code-signing identity found; set LODE_DRILL_SIGN_IDENTITY" >&2; exit 1; }
echo "==> signing drill copies with identity $SIGN_IDENTITY"

echo "==> building old $OLD_VERSION and new $NEW_VERSION"
build_app "$OLD_VERSION" 1 "$WORK/old"
build_app "$NEW_VERSION" 2 "$WORK/new"

echo "==> packaging and signing update"
mkdir -p "$WORK/feed"
hdiutil create -volname "Lode" -srcfolder "$WORK/new/Lode.app" -ov -format UDZO \
    "$WORK/feed/Lode-$NEW_VERSION.dmg" > /dev/null
"$SPARKLE_BIN_DIR/generate_appcast" \
    --ed-key-file "$KEY_FILE" \
    --download-url-prefix "http://127.0.0.1:$PORT/" \
    -o "$WORK/feed/appcast.xml" \
    "$WORK/feed"

echo "==> serving feed on 127.0.0.1:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/feed" > "$WORK/http.log" 2>&1 &
SERVER_PID=$!
sleep 1

echo "==> running headless update drill"
swift build --package-path "$ROOT/scripts/update-drill" > "$WORK/drill-build.log" 2>&1 \
    || { tail -20 "$WORK/drill-build.log" >&2; exit 1; }
DRILL_BIN="$(swift build --package-path "$ROOT/scripts/update-drill" --show-bin-path)"
SPARKLE_FW="$(find "$ROOT/scripts/update-drill/.build/artifacts" -name Sparkle.framework -type d | head -1)"
[ -n "$SPARKLE_FW" ] || { echo "Sparkle.framework artifact not found" >&2; exit 1; }

# Sparkle's installer needs AuthorizationCreate, which recent macOS only grants
# to processes launched by LaunchServices from a real app bundle. Wrap the drill
# executable in a background-only .app and launch it with `open -W`.
DRILL_APP="$WORK/UpdateDrill.app"
mkdir -p "$DRILL_APP/Contents/MacOS" "$DRILL_APP/Contents/Frameworks"
cp "$DRILL_BIN/UpdateDrill" "$DRILL_APP/Contents/MacOS/UpdateDrill"
ditto "$SPARKLE_FW" "$DRILL_APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$DRILL_APP/Contents/MacOS/UpdateDrill" 2>/dev/null || true
cat > "$DRILL_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.coffic.lode.updatedrill</string>
<key>CFBundleName</key><string>UpdateDrill</string>
<key>CFBundleExecutable</key><string>UpdateDrill</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$DRILL_APP"
STATUS_FILE="$WORK/drill-status"
DRILL_LOG="$WORK/drill-output.log"
open -W "$DRILL_APP" --args \
    --app "$WORK/old/Lode.app" \
    --feed "http://127.0.0.1:$PORT/appcast.xml" \
    --expect "$NEW_VERSION" \
    --status-file "$STATUS_FILE" \
    --log-file "$DRILL_LOG"
cat "$DRILL_LOG" 2>/dev/null || true
DRILL_STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo 1)"
[ "$DRILL_STATUS" = "0" ] || { echo "drill failed with status $DRILL_STATUS" >&2; exit 1; }
