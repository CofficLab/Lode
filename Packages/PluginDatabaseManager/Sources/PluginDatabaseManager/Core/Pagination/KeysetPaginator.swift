import Foundation

/// keyset（游标）分页游标：记录上一页最后一行的排序键值与方向。
public struct KeysetCursor: Sendable, Equatable {
    public let column: String
    public let value: DatabaseValue
    public let ascending: Bool

    public init(column: String, value: DatabaseValue, ascending: Bool) {
        self.column = column
        self.value = value
        self.ascending = ascending
    }
}

/// keyset 分页纯函数核心：用 `WHERE key > last`（或 `<`）替代深翻页的
/// `LIMIT … OFFSET …`，避免 OFFSET 随页深线性扫描。仅适用于按单一主键列
/// 排序的场景（唯一且非空，保证遍历确定、无间隙、无重复）。
public enum KeysetPaginator {
    /// 是否可用 keyset：必须按单一主键列排序。
    public static func isApplicable(orderColumn: String?, keyColumns: [String]) -> Bool {
        guard let orderColumn, keyColumns.count == 1 else { return false }
        return keyColumns[0] == orderColumn
    }

    /// 从当前页最后一行提取下一页游标；空页 / 缺列 / NULL 键值 → nil。
    public static func cursor(from result: QueryResult, column: String, ascending: Bool) -> KeysetCursor? {
        guard let last = result.rows.last,
              let index = result.columns.firstIndex(of: column),
              index < last.count else { return nil }
        let value = last[index]
        guard value != .null else { return nil }
        return KeysetCursor(column: column, value: value, ascending: ascending)
    }

    /// 将游标条件并入现有筛选 WHERE，并按方言续接参数编号。
    /// - quote: 标识符引用函数（由调用方按方言提供）。
    /// - Returns: 合并后的 WHERE 子句（不含 `WHERE` 关键字，nil 表示无条件）与参数。
    public static func combineWhere(
        filterClause: String?,
        filterParams: [DatabaseValue],
        cursor: KeysetCursor?,
        dialect: DatabaseType,
        quote: (String) -> String
    ) -> (clause: String?, params: [DatabaseValue]) {
        guard let cursor else { return (filterClause, filterParams) }
        let placeholder = dialect == .postgresql ? "$\(filterParams.count + 1)" : "?"
        let op = cursor.ascending ? ">" : "<"
        let fragment = "\(quote(cursor.column)) \(op) \(placeholder)"
        let clause: String
        if let filterClause, !filterClause.isEmpty {
            clause = "(\(filterClause)) AND \(fragment)"
        } else {
            clause = fragment
        }
        return (clause, filterParams + [cursor.value])
    }
}