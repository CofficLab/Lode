import Foundation

/// 收藏的查询：按连接（configName）组织，可载入编辑器或重执行。
public struct SavedQuery: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sql: String
    public var configName: String
    public var database: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sql: String,
        configName: String,
        database: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sql = sql
        self.configName = configName
        self.database = database
        self.createdAt = createdAt
    }
}

/// 代码片段：带 `${name}` / `${name:default}` 占位符，插入编辑器时展开。
public struct Snippet: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var body: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, body: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.body = body
        self.createdAt = createdAt
    }
}