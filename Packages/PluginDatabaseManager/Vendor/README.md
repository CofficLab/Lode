# Vendored SSH cryptography

The SSH tunnel feature (`LibSSH2TunnelEngine`) links two third-party libraries,
both vendored here so the app has **no runtime dependency on Homebrew or any
system package manager**.

## Components

| Component | Version | License | Form |
|-----------|---------|---------|------|
| libssh2 | 1.11.2_DEV (commit `e75fa9a539d21e82d4920c126662e36984e97d61`) | BSD-3-Clause | Source, compiled by SwiftPM as the `CLibSSH2` target (`../Sources/CLibSSH2`) |
| OpenSSL (libcrypto) | 3.5.4 | Apache-2.0 | Prebuilt universal static `libcrypto.a` in `COpenSSL.xcframework` |

Both licenses are compatible with this project's GPLv3.

## libssh2

Vendored as plain C source under `../Sources/CLibSSH2` (`include/` public
headers, `src/` implementation). It is built against the OpenSSL backend
(`LIBSSH2_OPENSSL`) using a hand-written macOS configuration
(`src/libssh2_config.h`). The OS/400 backend (`os400qc3.*`) is omitted because
it is platform-specific and not needed on macOS. The upstream license is in
`../Sources/CLibSSH2/COPYING`.

Upstream: https://github.com/libssh2/libssh2

## OpenSSL

Only `libcrypto` is needed (libssh2's crypto backend). It is built from the
official source tarball as a **universal (arm64 + x86_64) static library** with
a macOS 14.0 deployment target, then packaged as `COpenSSL.xcframework` via
`xcodebuild -create-xcframework`. The framework carries a module map so Swift
can `import COpenSSL`.

The corresponding source is obtainable from the official tarball pinned by
SHA256 in `VERSIONS`. To regenerate the exact binary from source, run:

```sh
bash Packages/PluginDatabaseManager/Scripts/build-openssl-xcframework.sh
```

The script downloads the official tarball, verifies its SHA256, builds both
architecture slices with OpenSSL's own `Configure` + `Makefile`, and rebuilds
`COpenSSL.xcframework` in place. Build flags:
`no-asm no-shared no-tests no-docs no-legacy no-apps no-module`.

For an offline or CI rebuild, point `OPENSSL_TARBALL` at an already-downloaded
copy of the tarball (it is still SHA256-verified before use):

```sh
OPENSSL_TARBALL=/path/to/openssl-3.5.4.tar.gz \
  bash Packages/PluginDatabaseManager/Scripts/build-openssl-xcframework.sh
```

Upstream: https://www.openssl.org/source/