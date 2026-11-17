# Release pipeline

Lode ships outside the Mac App Store as a notarized, Hardened Runtime build
with Sparkle auto-update. This directory contains the release tooling; no
credentials or signing keys live in the repository.

## One-time setup

1. **EdDSA update-signing key.** Generate a key pair and keep the private key
   outside the repository (for example in a password manager or an offline
   volume):

   ```sh
   # Sparkle's tool stores the private key in the login keychain:
   generate_keys            # prints the public key
   generate_keys -x private.key.b64   # export for file-based signing
   ```

   The public key is already committed in `LodeApp/Lode-Info.plist`
   (`SUPublicEDKey`). If you rotate the key, update that plist value and ship
   the change before publishing updates signed with the new key.

2. **Notarization credentials.** Store an App Store Connect API key (or
   app-specific password) once:

   ```sh
   xcrun notarytool store-credentials LODE_NOTARY_PROFILE \
       --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
   ```

3. **Sparkle tools.** `release.sh` / `make-appcast.sh` download the official
   Sparkle distribution into the user cache automatically, or use
   `SPARKLE_BIN_DIR` to point at an existing `bin/` directory.

## Cutting a release

```sh
export LODE_SPARKLE_ED_KEY_FILE=/secure/path/private.key.b64
export LODE_NOTARY_PROFILE=LODE_NOTARY_PROFILE
export LODE_DOWNLOAD_URL_PREFIX=https://github.com/CofficLab/Lode/releases/download/v1.0.1/
scripts/release/release.sh 1.0.1 2
```

The script builds Release, notarizes and staples the app, packages a DMG,
signs the update with EdDSA and writes `appcast.xml`. Publish the DMG and
`appcast.xml` as assets of the GitHub release tagged `v1.0.1`; the app's
`SUFeedURL` points at `releases/latest/download/appcast.xml`, so the newest
release's appcast is what clients read.

## Update drill (acceptance)

`drill-update.sh` proves the whole update path without touching production:
it builds an old and a new version, serves a signed appcast plus DMG over
local HTTP, and drives the old app through discovery, download, signature
verification and installation with a headless Sparkle user driver
(`scripts/update-drill`). It fails unless the old app bundle ends up at the
new version. Both copies are signed with one real code-signing identity from
the keychain (Sparkle rejects updates whose signature does not match the old
app; override the identity with `LODE_DRILL_SIGN_IDENTITY`). The headless
driver runs as a background app bundle launched via LaunchServices, which
recent macOS requires for the installer's authorization.

```sh
LODE_SPARKLE_ED_KEY_FILE=/secure/path/private.key.b64 scripts/release/drill-update.sh
```

## Security notes

- Updates are accepted only with a valid EdDSA signature matching
  `SUPublicEDKey`; the feed must be HTTPS in production.
- The private signing key and notarization credentials never enter the
  repository or CI logs.
- See `docs/security-model.md` for the sandbox / Hardened Runtime decision.