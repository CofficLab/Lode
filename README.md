# Lode

Lode is a native macOS database manager for SQLite, MySQL, PostgreSQL, and Redis. It provides connection management, an object tree, a SQL editor with tree-sitter syntax highlighting, table structure and data editing, query history, and database tools for agents.

Lode was extracted from [Lumi](https://github.com/CofficLab/Lumi) and keeps Lumi's Kernel / Provider / Plugin architecture: the kernel owns lifecycle and dependency wiring, providers expose host capabilities, and plugins implement database features.

📖 English | [中文版](README_zh.md)

[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://developer.apple.com/macos/)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## Features

- **Multiple databases** — SQLite, MySQL, PostgreSQL, and Redis connections in one workspace.
- **Connection management** — save, edit, and switch between connections, with per-connection settings and capabilities.
- **Object tree** — browse databases, tables, views, indexes, and triggers from the sidebar.
- **SQL editor** — tree-sitter based SQL syntax highlighting and a dedicated editor host.
- **Table editing** — inspect table structure and edit data with an in-memory change queue before writing back.
- **Query history** — persisted history for revisiting and re-running previous queries.
- **Agent tools** — database tools that let the agent inspect schemas and run queries.

## Architecture

| Path | Description |
|------|-------------|
| `LodeApp/` | SwiftUI app entry point, Info.plist, and entitlements |
| `Packages/FactoryDatabaseManager/` | Composition root: KernelFactory, ProviderFactory, ViewFactory, and the dedicated plugin catalog |
| `Packages/PluginDatabaseManager/` | Database plugin: connections, queries, object tree, editor, and agent tools |
| `Packages/PluginCodeEditorHost/` | Editor host plugin used by the SQL editor |
| `Packages/Kit*` / `Packages/Provider*` / `Packages/Plugin*` | Minimal dependency closure carried over from Lumi |
| `project.yml` | XcodeGen project description |

Shared capabilities (LumiKernel, LumiProviders, LumiUI, and others) are consumed as remote Swift packages and are not copied into this repository.

## Build

Requirements:

- macOS 14 or later
- Xcode 27.0 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```sh
xcodegen generate
xcodebuild -project Lode.xcodeproj -scheme Lode -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

Builds must target a single architecture: `generic/platform=macOS` compiles both arm64 and x86_64 and trips the single-architecture validation for the ACP executable.

`Lode.xcodeproj` is generated from `project.yml`; do not edit the project file by hand.

## Testing

```sh
swift test --package-path Packages/PluginDatabaseManager
swift test --package-path Packages/FactoryDatabaseManager
```

### Integration tests (real engines)

Driver handshake, introspection, edit/commit, filtering, TLS, SSH tunnelling and
import/export paths are covered by integration tests that talk to real database
servers. They are skipped by default and enabled by `LODE_TEST_*` environment
variables. A disposable Docker harness brings up MySQL, PostgreSQL, Redis, TLS
variants of PostgreSQL/Redis and an SSH jump host, generates throwaway TLS
fixtures, runs the suite and tears everything down:

```sh
# Requires Docker (with the compose plugin) and OpenSSL.
scripts/integration/run-all-tests.sh                 # whole plugin suite
scripts/integration/run-all-tests.sh SSHTunnelIntegrationTests   # one suite
```

The harness publishes MySQL on 33061, PostgreSQL on 54321, Redis on 63791,
PostgreSQL TLS on 54322, Redis TLS on 63792 and SSH on 2222. Generated certificates
and ACL files live in `scripts/integration/.fixtures/` (gitignored); no credentials
are committed. To run against engines you manage yourself, export the
`LODE_TEST_*_PORT` variables (and `LODE_TEST_TLS_CA` / `LODE_TEST_TLS_WRONG_CA` for
the TLS suites) and run `swift test` directly.

If the SSH image build cannot reach the official Alpine package CDN, point it at a
reachable mirror, e.g. `LODE_APK_MIRROR=https://mirrors.aliyun.com scripts/integration/run-all-tests.sh`.

### Launch performance

Launch is instrumented in three phases — kernel assembly, first window
construction and first database connection — with signposts and a rolling
history persisted to UserDefaults. CI enforces an assembly budget against
`scripts/perf/launch-baseline.json`: locally the median kernel-assembly time
must stay within 2x of the baseline, and a busy-spin CPU probe relaxes that
to 5x when it detects scheduler contention (so concurrent builds do not trip
the gate); on shared CI runners a flat 5x wall-clock tolerance always applies
(they run several times slower). Debug builds additionally run a main-thread
stall watchdog that logs any main-queue block longer than 250 ms.

```sh
# Real cold-launch medians from a built app (assembly / firstWindow / firstConnection):
scripts/perf/measure-launch.sh /path/to/Lode.app 5

# Regenerate the assembly baseline deliberately, then commit the new value:
LODE_PERF_MEASURE=1 swift test --package-path Packages/FactoryDatabaseManager --filter measureAssemblyBaseline
```

## License

GPL-3.0. See [LICENSE](LICENSE).
