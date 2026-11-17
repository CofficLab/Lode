#!/bin/bash
# 定位 Sparkle 命令行工具（generate_appcast / sign_update）。
# 优先使用 SPARKLE_BIN_DIR；否则下载官方发行包到用户缓存目录（不入库）。
set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.10.1}"

ensure_sparkle_tools() {
    if [[ -n "${SPARKLE_BIN_DIR:-}" && -x "$SPARKLE_BIN_DIR/generate_appcast" ]]; then
        return 0
    fi
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/lode-sparkle/$SPARKLE_VERSION"
    if [[ ! -x "$cache/bin/generate_appcast" ]]; then
        mkdir -p "$cache"
        local tarball="$cache/Sparkle-$SPARKLE_VERSION.tar.xz"
        if [[ ! -f "$tarball" ]]; then
            curl -fsSL --retry 3 -o "$tarball" \
                "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
        fi
        tar -xf "$tarball" -C "$cache"
    fi
    SPARKLE_BIN_DIR="$cache/bin"
}