import Foundation

/// 行数计数策略：优先用引擎自带的统计估算，避免百万行表每次浏览都做一次
/// 全表 `COUNT(*)` 扫描；估算不可用（SQLite 无廉价统计、PG 未 ANALYZE）或
/// 带筛选时降级为精确 `COUNT(*)`。所有函数均为纯函数，便于单元测试。
public enum RowCountEstimator {
    /// 一次估算查询：SQL 文本 + 绑定参数（占位符遵循各引擎方言）。
    public struct EstimateQuery: Sendable, Equatable {
        public let sql: String
        public let params: [DatabaseValue]

        public init(sql: String, params: [DatabaseValue]) {
            self.sql = sql
            self.params = params
        }
    }

    /// 引擎级近似计数查询。
    /// - Parameters:
    ///   - type: 数据库类型。
    ///   - schema: PG 的 schema（nil/空 → public）；MySQL 的库名（nil/空 → 无法估算）。
    ///   - table: 表名（未限定）。
    /// - Returns: 估算查询；SQLite/Redis 或 MySQL 缺库名时返回 nil（降级精确计数）。
    public static func estimateQuery(for type: DatabaseType, schema: String?, table: String) -> EstimateQuery? {
        switch type {
        case .postgresql:
            let ns = (schema?.isEmpty == false) ? schema! : "public"
            return EstimateQuery(
                sql: """
                SELECT c.reltuples FROM pg_class c \
                JOIN pg_namespace n ON n.oid = c.relnamespace \
                WHERE n.nspname = $1 AND c.relname = $2
                """,
                params: [.string(ns), .string(table)])
        case .mysql:
            guard let db = schema, !db.isEmpty else { return nil }
            return EstimateQuery(
                sql: "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
                params: [.string(db), .string(table)])
        case .sqlite, .redis:
            return nil
        }
    }

    /// 解析估算结果为行数。
    /// PG `reltuples` 在从未 ANALYZE 时为 -1，MySQL `TABLE_ROWS` 可能为 NULL；
    /// 这些情况返回 nil，调用方据此降级到精确计数。负值一律视为不可用。
    public static func interpretEstimate(_ value: DatabaseValue) -> Int? {
        let parsed: Int?
        switch value {
        case .integer(let v): parsed = v
        case .double(let v): parsed = Int(v)
        case .string(let s): parsed = Int(s)
        default: parsed = nil
        }
        guard let count = parsed, count >= 0 else { return nil }
        return count
    }

    /// 精确计数 SQL（可带 WHERE 子句，子句不含 `WHERE` 关键字）。
    public static func exactQuery(tableExpr: String, whereClause: String?) -> String {
        var sql = "SELECT COUNT(*) FROM \(tableExpr)"
        if let clause = whereClause, !clause.isEmpty {
            sql += " WHERE \(clause)"
        }
        return sql
    }
}