#!/bin/bash
# 本地升级演练：构建旧/新两个版本，本地 HTTP  serve appcast + DMG，
# 用无头 UpdateDrill 驱动旧版本完成 发现→下载→验签→安装 全链路并核对版本。
# 用法: LODE_SPARKLE_ED_KEY_FILE=<私钥文件> ./drill-update.sh [旧版本] [新版本]
set -euo pipefail

OLD_VERSION="${1:-1.0.0}"
NEW_VERSION="${2:-1.0.1}"
KEY_FILE="${LODE_SPARKLE_ED_KEY_FILE:?set LODE_SPARKLE_ED_KEY_FILE}"
PORT="${LODE_DRILL_PORT:-8765}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lode-update-drill.XXXXXX")"
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
    codesign --force --deep --sign - "$dest/Lode.app"
}

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
swift run --package-path "$ROOT/scripts/update-drill" UpdateDrill \
    --app "$WORK/old/Lode.app" \
    --feed "http://127.0.0.1:$PORT/appcast.xml" \
    --expect "$NEW_VERSION"