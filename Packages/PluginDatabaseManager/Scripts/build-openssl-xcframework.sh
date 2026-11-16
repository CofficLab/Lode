#!/bin/bash
# Reproducibly rebuild Vendor/COpenSSL.xcframework from the official OpenSSL
# source tarball. The vendored binary is a universal (arm64 + x86_64) static
# libcrypto.a; this script regenerates it byte-for-feature from upstream source
# so the corresponding source is always obtainable (GPLv3 source provision).
#
# Requirements: macOS with Xcode command line tools (perl, make, lipo,
# xcodebuild), curl, shasum. Run from anywhere:
#   bash Packages/PluginDatabaseManager/Scripts/build-openssl-xcframework.sh
set -euo pipefail

OPENSSL_VERSION="3.5.4"
OPENSSL_SHA256="967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99"
PRIMARY_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
MIRROR_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
DEPLOYMENT_TARGET="14.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PKG_DIR/Vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TARBALL="$WORK/openssl-${OPENSSL_VERSION}.tar.gz"
if [ -n "${OPENSSL_TARBALL:-}" ] && [ -f "$OPENSSL_TARBALL" ]; then
    echo "==> Using local tarball: $OPENSSL_TARBALL"
    cp "$OPENSSL_TARBALL" "$TARBALL"
else
    echo "==> Downloading OpenSSL ${OPENSSL_VERSION}"
    if ! curl -fL --retry 3 --connect-timeout 30 -o "$TARBALL" "$PRIMARY_URL"; then
        echo "==> Primary failed, trying mirror"
        curl -fL --retry 3 --connect-timeout 30 -o "$TARBALL" "$MIRROR_URL"
    fi
fi

echo "==> Verifying SHA256"
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL" != "$OPENSSL_SHA256" ]; then
    echo "SHA256 mismatch: expected $OPENSSL_SHA256, got $ACTUAL" >&2
    exit 1
fi

echo "==> Extracting"
tar -xzf "$TARBALL" -C "$WORK"
SRC="$WORK/openssl-${OPENSSL_VERSION}"
OUT="$WORK/out"
mkdir -p "$OUT"
COMMON=(no-asm no-shared no-tests no-docs no-legacy no-apps no-module "-mmacosx-version-min=${DEPLOYMENT_TARGET}")

build_arch() {
    local arch="$1" target="$2"
    echo "==> Building $arch"
    ( cd "$SRC"
      make distclean >/dev/null 2>&1 || true
      # Neutral canonical prefix: only affects embedded OPENSSLDIR/ENGINESDIR/
      # MODULESDIR strings (we never `make install` or load config/engines),
      # so the binary carries no machine-specific build paths.
      perl ./Configure "$target" "${COMMON[@]}" --prefix=/usr/local --openssldir=/usr/local/ssl
      make build_generated
      make -j"$(sysctl -n hw.ncpu)" libcrypto.a
      cp libcrypto.a "$OUT/libcrypto-$arch.a" )
}

build_arch arm64 darwin64-arm64-cc
cp -R "$SRC/include" "$OUT/headers"
build_arch x86_64 darwin64-x86_64-cc

echo "==> Creating universal binary"
lipo -create "$OUT/libcrypto-arm64.a" "$OUT/libcrypto-x86_64.a" -output "$OUT/libcrypto.a"
lipo -info "$OUT/libcrypto.a"

echo "==> Packaging xcframework"
rm -rf "$VENDOR_DIR/COpenSSL.xcframework"
xcodebuild -create-xcframework \
    -library "$OUT/libcrypto.a" \
    -headers "$OUT/headers" \
    -output "$VENDOR_DIR/COpenSSL.xcframework"
printf 'module COpenSSL {\n  umbrella "openssl"\n  export *\n}\n' \
    > "$VENDOR_DIR/COpenSSL.xcframework/macos-arm64_x86_64/Headers/module.modulemap"

echo "==> Done: $VENDOR_DIR/COpenSSL.xcframework"