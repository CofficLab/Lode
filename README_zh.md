# Lode

Lode 是一款 macOS 原生数据库管理器，支持 SQLite、MySQL、PostgreSQL 和 Redis。它提供连接管理、对象树浏览、SQL 编辑器（tree-sitter 语法高亮）、表结构与数据编辑、查询历史，以及面向 Agent 的数据库工具。

Lode 从 [Lumi](https://github.com/CofficLab/Lumi) 中剥离而来，保留 Lumi 的 Kernel / Provider / Plugin 架构：内核负责生命周期与依赖装配，Provider 提供宿主能力，Plugin 实现数据库功能。

📖 [中文版](README_zh.md) | [English](README.md)

[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://developer.apple.com/macos/)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## 功能特性

- **多数据库支持** — 在同一工作区管理 SQLite、MySQL、PostgreSQL 和 Redis 连接。
- **连接管理** — 保存、编辑与切换连接，并按连接维护设置与能力。
- **对象树** — 在侧边栏浏览数据库、表、视图、索引和触发器。
- **SQL 编辑器** — 基于 tree-sitter 的 SQL 语法高亮，配合专用编辑器宿主。
- **表数据编辑** — 查看表结构并编辑数据，修改先进入内存变更队列，再统一写回。
- **查询历史** — 持久化历史记录，便于回看与重新执行。
- **Agent 工具** — 提供数据库工具，让 Agent 读取表结构并执行查询。

## 结构

| 路径 | 说明 |
|------|------|
| `LodeApp/` | SwiftUI 应用入口、Info.plist、entitlements |
| `Packages/FactoryDatabaseManager/` | 组合根：KernelFactory、ProviderFactory、ViewFactory 与专用插件目录 |
| `Packages/PluginDatabaseManager/` | 数据库插件：连接、查询、对象树、编辑器、Agent 工具 |
| `Packages/PluginCodeEditorHost/` | 编辑器宿主插件（SQL 编辑器依赖） |
| `Packages/Kit*` / `Packages/Provider*` / `Packages/Plugin*` | 从 Lumi 剥离的最小依赖闭包 |
| `project.yml` | XcodeGen 工程描述 |

共享能力（LumiKernel、LumiProviders、LumiUI 等）通过 Swift Package 远端依赖引入，不在本仓库复制。

## 构建

环境要求：

- macOS 14 或更高版本
- Xcode 27.0 或更高版本
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

```sh
xcodegen generate
xcodebuild -project Lode.xcodeproj -scheme Lode -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

必须单架构构建：`generic/platform=macOS` 会同时编 arm64 与 x86_64，触发 ACP 可执行文件的单架构校验。

`Lode.xcodeproj` 由 `project.yml` 生成，不要直接手改工程文件。

## 测试

```sh
swift test --package-path Packages/PluginDatabaseManager
swift test --package-path Packages/FactoryDatabaseManager
```

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。
