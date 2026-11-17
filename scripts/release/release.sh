#!/bin/bash
# 完整发布管线：Release 构建 → 公证 → 装订 → DMG → EdDSA 签名 → appcast。
# 用法: ./release.sh <marketing-version> <build-number>
# 必需环境变量:
#   LODE_SPARKLE_ED_KEY_FILE  EdDSA 私钥文件（base64 文本，绝不入库）
#   LODE_NOTARY_PROFILE       notarytool keychain profile（xcrun notarytool store-credentials 创建）
#   LODE_DOWNLOAD_URL_PREFIX  更新包下载 URL 前缀（如 GitHub Release 资产地址）
set -euo pipefail

VERSION="${1:?usage: release.sh <marketing-version> <build-number>}"
BUILD="${2:?missing build number}"
KEY_FILE="${LODE_SPARKLE_ED_KEY_FILE:?set LODE_SPARKLE_ED_KEY_FILE}"
NOTARY_PROFILE="${LODE_NOTARY_PROFILE:?set LODE_NOTARY_PROFILE}"
URL_PREFIX="${LODE_DOWNLOAD_URL_PREFIX:?set LODE_DOWNLOAD_URL_PREFIX}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/release/$VERSION"
mkdir -p "$OUT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sparkle-tools.sh
source "$SCRIPT_DIR/sparkle-tools.sh"
ensure_sparkle_tools

echo "==> building Release $VERSION ($BUILD)"
xcodebuild -project "$ROOT/Lode.xcodeproj" -scheme Lode -configuration Release \
    -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    -skipPackagePluginValidation -skipMacroValidation \
    SYMROOT="$OUT/sym" build

APP="$OUT/sym/Release/Lode.app"
[[ -d "$APP" ]] || { echo "built app not found at $APP" >&2; exit 1; }

echo "==> notarizing"
ditto -c -k --keepParent "$APP" "$OUT/Lode-$VERSION.zip"
xcrun notarytool submit "$OUT/Lode-$VERSION.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> packaging DMG"
DMG="$OUT/Lode-$VERSION.dmg"
hdiutil create -volname "Lode" -srcfolder "$APP" -ov -format UDZO "$DMG"
xcrun stapler staple "$DMG" || true

echo "==> signing update and generating appcast"
"$SPARKLE_BIN_DIR/sign_update" --ed-key-file "$KEY_FILE" "$DMG"
"$SCRIPT_DIR/make-appcast.sh" "$OUT" "$URL_PREFIX" "$OUT/appcast.xml"

echo "==> done"
echo "publish these assets to the release:"
echo "  $DMG"
echo "  $OUT/appcast.xml"
echo "SUFeedURL expects appcast.xml as a 'latest' release asset."