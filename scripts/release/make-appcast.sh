#!/bin/bash
# 生成 Sparkle appcast：扫描目录中的 DMG/ZIP 更新包，用 EdDSA 私钥签名。
# 用法: LODE_SPARKLE_ED_KEY_FILE=<私钥文件> ./make-appcast.sh <更新包目录> <下载URL前缀> [输出文件]
# 私钥是 base64 文本文件（generate_keys -x 导出格式），绝不入库。
set -euo pipefail

ARCHIVE_DIR="${1:?usage: make-appcast.sh <archive-dir> <download-url-prefix> [output]}"
URL_PREFIX="${2:?missing download URL prefix}"
OUTPUT="${3:-$ARCHIVE_DIR/appcast.xml}"
KEY_FILE="${LODE_SPARKLE_ED_KEY_FILE:?set LODE_SPARKLE_ED_KEY_FILE to the EdDSA private key file}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sparkle-tools.sh
source "$SCRIPT_DIR/sparkle-tools.sh"
ensure_sparkle_tools

"$SPARKLE_BIN_DIR/generate_appcast" \
    --ed-key-file "$KEY_FILE" \
    --download-url-prefix "$URL_PREFIX" \
    -o "$OUTPUT" \
    "$ARCHIVE_DIR"

echo "appcast written to $OUTPUT"