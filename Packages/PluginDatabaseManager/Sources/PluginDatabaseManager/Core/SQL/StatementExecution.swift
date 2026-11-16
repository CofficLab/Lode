import Foundation

/// 多语句批量执行策略（⌘⇧↩）。
public enum BatchExecutionPolicy: String, CaseIterable, Sendable, Identifiable {
    /// 逐句执行，任一语句失败仍继续后续语句（默认）。
    case continueOnError
    /// 包裹在单个事务中，任一语句失败即整体回滚（MySQL/PG/SQLite；Redis 走 MULTI/EXEC）。
    case wrapInTransaction

    public var id: String { rawValue }
}

/// 多语句执行中单条语句的执行结果。
public struct StatementExecution: Identifiable, Sendable {
    public let id: UUID
    /// 已 trim 过的语句文本。
    public let sql: String
    /// 成功时返回查询结果；失败时 `errorMessage` 非空。
    public var result: QueryResult?
    public var errorMessage: String?
    /// 失败时的语义分类，供错误条显示本地化标题。
    public var errorCategory: DatabaseErrorCategory?
    /// 执行耗时（毫秒）。
    public var durationMs: Double

    public var succeeded: Bool { errorMessage == nil }

    public init(sql: String, result: QueryResult? = nil, errorMessage: String? = nil, errorCategory: DatabaseErrorCategory? = nil, durationMs: Double = 0) {
        self.id = UUID()
        self.sql = sql
        self.result = result
        self.errorMessage = errorMessage
        self.errorCategory = errorCategory
        self.durationMs = durationMs
    }
}
