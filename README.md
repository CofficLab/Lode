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

## License

GPL-3.0. See [LICENSE](LICENSE).
