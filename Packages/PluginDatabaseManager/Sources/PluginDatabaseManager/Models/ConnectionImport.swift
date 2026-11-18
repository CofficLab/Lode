import Foundation

/// 可从其本机配置文件导入连接的外部数据库客户端。
/// 这是面向用户的互操作功能：解析各客户端的导出格式，映射为 Lode 的连接配置。
enum ConnectionImportSource: String, CaseIterable, Identifiable, Sendable {
    case tablePlus
    case sequelAce
    case dbeaver

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .tablePlus: return "TablePlus"
        case .sequelAce: return "Sequel Ace"
        case .dbeaver: return "DBeaver"
        }
    }
}

enum ConnectionImportError: LocalizedError, Equatable {
    case fileUnreadable
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .fileUnreadable: return "The connection file could not be read."
        case .unsupportedFormat: return "The file is not a recognized connection export."
        }
    }
}

/// 独立实现的连接导入解析器。
///
/// 安全约定：各客户端把密码/SSH 私钥存放在系统钥匙串或加密字段中，这些秘密无法也不应
/// 随导入明文搬运——导入只还原连接的非秘密字段（名称/引擎/主机/端口/库/用户/分组/颜色/
/// 启动脚本），密码与 SSH 凭据留空，由用户在导入后自行补填。
enum ConnectionImporter {
    /// 各客户端在本机的默认配置文件位置；不存在返回 nil。路径基于当前用户 home 动态拼接。
    static func defaultURL(for source: ConnectionImportSource) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return candidateURLs(for: source, home: home)
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 候选配置文件路径，按优先级排列：先常规安装路径，再 App Store 沙箱容器路径。
    static func candidateURLs(for source: ConnectionImportSource, home: URL) -> [URL] {
        switch source {
        case .tablePlus:
            return [
                home.appendingPathComponent("Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist"),
            ]
        case .sequelAce:
            return [
                home.appendingPathComponent("Library/Application Support/Sequel Ace/Data/Favorites.plist"),
                home.appendingPathComponent("Library/Application Support/Sequel Pro/Data/Favorites.plist"),
                home.appendingPathComponent("Library/Containers/com.sequel-ace.sequel-ace/Data/Library/Application Support/Sequel Ace/Data/Favorites.plist"),
                home.appendingPathComponent("Library/Containers/com.sequelpro.SequelPro/Data/Library/Application Support/Sequel Pro/Data/Favorites.plist"),
            ]
        case .dbeaver:
            return [
                home.appendingPathComponent("Library/DBeaverData/workspace6/General/.dbeaver/data-sources.json"),
                home.appendingPathComponent(".local/share/DBeaverData/workspace6/General/.dbeaver/data-sources.json"),
            ]
        }
    }

    /// 本机已安装（默认配置文件存在）的客户端来源。
    static func availableSources() -> [ConnectionImportSource] {
        ConnectionImportSource.allCases.filter { defaultURL(for: $0) != nil }
    }

    static func importConnections(from url: URL, source: ConnectionImportSource) throws -> [DatabaseConfig] {
        guard let data = try? Data(contentsOf: url) else { throw ConnectionImportError.fileUnreadable }
        return try parse(data, source: source)
    }

    static func parse(_ data: Data, source: ConnectionImportSource) throws -> [DatabaseConfig] {
        switch source {
        case .tablePlus: return try parseTablePlus(data)
        case .sequelAce: return try parseSequelAce(data)
        case .dbeaver: return try parseDBeaver(data)
        }
    }

    // MARK: - TablePlus（Connections.plist，顶层连接数组）

    private static func parseTablePlus(_ data: Data) throws -> [DatabaseConfig] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let entries = plist as? [[String: Any]] else {
            throw ConnectionImportError.unsupportedFormat
        }
        var result: [DatabaseConfig] = []
        for entry in entries {
            // 引擎类型在 Driver 字段（DatabaseType 常为空）。
            let driver = (entry["Driver"] as? String) ?? (entry["DatabaseType"] as? String) ?? ""
            guard let type = mapType(driver) else { continue }
            guard let name = trimmedString(entry["ConnectionName"]) else { continue }
            var config: DatabaseConfig
            if type == .sqlite {
                guard let path = trimmedString(entry["DatabasePath"]) else { continue }
                config = DatabaseConfig(name: name, type: type, database: path)
            } else {
                guard let host = trimmedString(entry["DatabaseHost"]) else { continue }
                let database = trimmedString(entry["DatabaseName"]) ?? (type == .redis ? "0" : "")
                config = DatabaseConfig(
                    name: name,
                    type: type,
                    host: host,
                    port: normalizedPort(entry["DatabasePort"], default: defaultPort(for: type)),
                    database: database,
                    username: trimmedString(entry["DatabaseUser"])
                )
            }
            if let group = trimmedString(entry["Enviroment"]) {
                config = config.withGroup(group)
            }
            if let hex = trimmedString(entry["statusColor"]) {
                config = config.withConnectionColor(color(fromHex: hex))
            }
            if let startup = trimmedString(entry["StartupCommands"]) {
                config = config.withStartupSQL(startup)
            }
            result.append(config)
        }
        return sortedForDisplay(result)
    }

    // MARK: - Sequel Ace / Sequel Pro（Favorites.plist，Favorites Root 下的 children/Children）

    private static func parseSequelAce(_ data: Data) throws -> [DatabaseConfig] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let favoritesRoot = root["Favorites Root"] as? [String: Any],
              let children = sequelChildren(of: favoritesRoot) else {
            throw ConnectionImportError.unsupportedFormat
        }
        var result: [DatabaseConfig] = []
        collectSequelFavorites(children, into: &result)
        return sortedForDisplay(result)
    }

    /// Sequel Pro 用小写 `children`，Sequel Ace 用大写 `Children`。
    private static func sequelChildren(of node: [String: Any]) -> [[String: Any]]? {
        (node["children"] as? [[String: Any]]) ?? (node["Children"] as? [[String: Any]])
    }

    /// 文件夹节点没有 host，递归展开其子节点；仅导入实际连接。
    private static func collectSequelFavorites(_ nodes: [[String: Any]], into result: inout [DatabaseConfig]) {
        for child in nodes {
            guard let host = trimmedString(child["host"]) else {
                if let sub = sequelChildren(of: child) {
                    collectSequelFavorites(sub, into: &result)
                }
                continue
            }
            let name = trimmedString(child["name"]) ?? host
            let type = mapType(child["type"] as? String ?? "mysql") ?? .mysql
            let config = DatabaseConfig(
                name: name,
                type: type,
                host: host,
                port: normalizedPort(child["port"], default: defaultPort(for: type)),
                database: trimmedString(child["database"]) ?? "",
                username: trimmedString(child["user"]),
                password: trimmedString(child["password"])
            )
            result.append(config)
        }
    }

    // MARK: - DBeaver（data-sources.json，connections 映射）

    private static func parseDBeaver(_ data: Data) throws -> [DatabaseConfig] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let connections = root["connections"] as? [String: Any] else {
            throw ConnectionImportError.unsupportedFormat
        }
        var result: [DatabaseConfig] = []
        for value in connections.values {
            guard let entry = value as? [String: Any],
                  let type = mapType(entry["provider"] as? String ?? "") else { continue }
            let configuration = entry["configuration"] as? [String: Any] ?? [:]
            let name = trimmedString(entry["name"]) ?? trimmedString(configuration["database"]) ?? type.rawValue
            var config: DatabaseConfig
            if type == .sqlite {
                guard let path = trimmedString(configuration["database"]) ?? sqlitePath(fromJDBCURL: configuration["url"] as? String) else { continue }
                config = DatabaseConfig(name: name, type: type, database: path)
            } else {
                guard let host = trimmedString(configuration["host"]) else { continue }
                let database = trimmedString(configuration["database"]) ?? (type == .redis ? "0" : "")
                config = DatabaseConfig(
                    name: name,
                    type: type,
                    host: host,
                    port: normalizedPort(configuration["port"], default: defaultPort(for: type)),
                    database: database,
                    username: trimmedString(configuration["user"])
                )
            }
            // DBeaver 密码为加密字段，不导入。
            result.append(config)
        }
        return sortedForDisplay(result)
    }

    // MARK: - 共享映射工具

    private static func mapType(_ raw: String) -> DatabaseType? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mysql", "mariadb": return .mysql
        case "postgresql", "postgres", "pgsql": return .postgresql
        case "sqlite", "sqlite3": return .sqlite
        case "redis": return .redis
        default: return nil
        }
    }

    private static func defaultPort(for type: DatabaseType) -> Int {
        switch type {
        case .mysql: return 3306
        case .postgresql: return 5432
        case .redis: return 6379
        case .sqlite: return 0
        }
    }

    private static func trimmedString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedPort(_ raw: Any?, default fallback: Int) -> Int {
        if let value = raw as? Int, (1...65535).contains(value) { return value }
        if let value = raw as? String,
           let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           (1...65535).contains(parsed) { return parsed }
        return fallback
    }

    private static func sqlitePath(fromJDBCURL url: String?) -> String? {
        guard let url, let range = url.range(of: "jdbc:sqlite:") else { return nil }
        let path = String(url[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func sortedForDisplay(_ configs: [DatabaseConfig]) -> [DatabaseConfig] {
        configs.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return ($0.database, $0.host ?? "") < ($1.database, $1.host ?? "")
        }
    }

    /// 把十六进制状态色（如 `#DAEBC2`）按色相映射到 Lode 的语义连接色。
    /// 灰/黑/白等低饱和或极暗色归为 none。
    static func color(fromHex hex: String) -> ConnectionColor {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return .none }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        if delta < 0.12 || maxValue < 0.15 { return .none }
        var hue: Double
        if maxValue == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15: return .red
        case ..<70: return .orange
        case ..<170: return .green
        case ..<200: return .cyan
        case ..<255: return .blue
        case ..<345: return .purple
        default: return .red
        }
    }
}