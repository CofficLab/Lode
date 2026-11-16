import Foundation

/// 查询历史中的一条记录。
public struct QueryHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sql: String
    public let configName: String
    public let database: String
    public let executedAt: Date
    /// 用户置顶（收藏）标记：置顶条目排在最前，且不受保留期/数量上限清理。
    public let pinned: Bool

    public init(
        id: UUID = UUID(),
        sql: String,
        configName: String,
        database: String,
        executedAt: Date = Date(),
        pinned: Bool = false
    ) {
        self.id = id
        self.sql = sql
        self.configName = configName
        self.database = database
        self.executedAt = executedAt
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, sql, configName, database, executedAt, pinned
    }

    // 旧版 UserDefaults JSON 不含 pinned 字段，解码时缺省为 false（迁移兼容）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sql = try container.decode(String.self, forKey: .sql)
        configName = try container.decode(String.self, forKey: .configName)
        database = try container.decode(String.self, forKey: .database)
        executedAt = try container.decode(Date.self, forKey: .executedAt)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}