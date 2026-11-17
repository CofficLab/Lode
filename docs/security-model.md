# Lode security model

This document records Lode's deliberate application-sandbox decision and the
hardening that stands in for it. It is a decision record, not a tutorial.

## Decision: App Sandbox is intentionally disabled

`project.yml` sets `ENABLE_APP_SANDBOX: NO`. Enabling the sandbox would break
core, shipped functionality that cannot be expressed with sandbox entitlements
alone:

- **SSH agent forwarding.** libssh2 reads the agent socket from `SSH_AUTH_SOCK`
  (`Sources/CLibSSH2/src/agent.c`). The socket lives outside the app container
  (typically under `$TMPDIR`/`/private/tmp` owned by the user's session); a
  sandboxed process cannot reach it, so agent-based SSH auth would fail.
- **Password-from-command.** The `command` password source executes
  `/bin/sh -c <user command>` and captures stdout
  (`Internal/PasswordSourceResolver.swift:82`). Sandboxed apps cannot spawn
  arbitrary shells or read the files those commands touch.
- **SSH tunnel local listener.** The tunnel binds a raw POSIX listener on
  `127.0.0.1` (`Internal/LibSSH2TunnelEngine.swift:216`). Under the sandbox this
  requires `com.apple.security.network.server` and still interacts poorly with
  the agent/socket restrictions above.
- **Connection import from other clients.** Import reads other applications'
  preference files under `~/Library/Application Support`
  (`Models/ConnectionImport.swift:46`, `:50`, `:55`). The sandbox blocks reading
  another app's data unless the user explicitly selects each file.
- **Typed file paths.** SQLite database paths, TLS certificate/key paths and SSH
  key paths are typed into the connection form, not chosen through an open
  panel. The sandbox only grants access to user-selected files (or paths covered
  by a security-scoped bookmark), so typed paths would be unreadable.

Because these are central to a database client (SSH tunnelling, flexible
credentials, interoperability), the project chooses **not** to sandbox and to
harden through the mechanisms below instead.

## Alternative hardening in place

- **Hardened Runtime** is enabled (`ENABLE_HARDENED_RUNTIME: YES`). This enforces
  code-signing integrity, restricts dylib hijacking and `DYLD_*` injection, and
  is a prerequisite for notarization.
- **User-selected file access.** `ENABLE_USER_SELECTED_FILES: readwrite` grants
  read/write to files the user picks through open/save panels; the entitlement is
  declared explicitly in `LodeApp/App.entitlements`.
- **Security-scoped bookmarks.** `SecurityScopedBookmarkStore` persists a
  bookmark for each user-selected SQL file and resolves it (with
  `startAccessingSecurityScopedResource`) on every later read/write/reload. This
  keeps remembered files working across relaunches and file moves, and is the
  exact mechanism the sandbox would require — so the file-access layer is already
  sandbox-ready even though the sandbox is off.
- **Notarization-ready signing.** Automatic signing with a Developer ID team
  (`DEVELOPMENT_TEAM`) plus Hardened Runtime produces a build that can be
  notarized for distribution outside the Mac App Store. The release workflow
  signs with a secure timestamp and submits for notarization.

## What enabling the sandbox later would require

If a future distribution channel (e.g. Mac App Store) mandates the sandbox, the
path is:

1. Add `com.apple.security.network.client` and `com.apple.security.network.server`
   (tunnel listener), and `com.apple.security.files.user-selected.read-write`.
2. Route **every** typed file path (SQLite/TLS/SSH) through a panel or a persisted
   security-scoped bookmark; `SecurityScopedBookmarkStore` is the foundation.
3. Replace SSH-agent forwarding with key-file auth scoped via bookmarks, and
   replace password-from-command with a bookmark-scoped file or the keychain.
4. Make connection import a user-driven file selection rather than silent reads
   of other apps' containers.
5. Add `keychain-access-groups` if migrating to the data-protection keychain.

Until those trade-offs are acceptable, the non-sandboxed Hardened Runtime build
is the supported configuration.