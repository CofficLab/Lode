import Foundation

/// 网格查找范围：当前页（客户端匹配）或全量（服务端 LIKE）。
public enum GridFindScope: String, Sendable, CaseIterable, Identifiable {
    case currentPage
    case allRows

    public var id: String { rawValue }
}

/// 网格查找的纯逻辑：当前页单元格匹配 + 全量服务端 LIKE 子句生成。
///
/// 与渲染层解耦，便于单元测试。服务端查找在所有非二进制列上 OR 组合
/// 大小写不敏感的 LIKE，值绝不内插进 SQL（参数化绑定，防注入）。
public enum GridFind {
    /// 单元格位置（行索引 + 数据列索引）。
    public struct CellPosition: Hashable, Sendable {
        public let row: Int
        public let col: Int
        public init(row: Int, col: Int) {
            self.row = row
            self.col = col
        }
    }

    /// 当前页内显示文本包含 term 的全部单元格（大小写不敏感子串，按行优先）。
    /// `text` 提供与网格渲染一致的单元格显示文本。term 为空返回空数组。
    public static func matches(
        columns: [String],
        rows: [[DatabaseValue]],
        term: String,
        text: (DatabaseValue) -> String
    ) -> [CellPosition] {
        let needle = term.lowercased()
        guard !needle.isEmpty else { return [] }
        var out: [CellPosition] = []
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() where c < columns.count {
                if text(value).lowercased().contains(needle) {
                    out.append(CellPosition(row: r, col: c))
                }
            }
        }
        return out
    }

    /// 全量服务端查找的 WHERE 子句（不含 `WHERE`）与绑定参数。
    ///
    /// 在所有非二进制列上 OR 组合 `LOWER(col) LIKE LOWER(?) ESCAPE '!'`。
    /// 占位符按方言选择：PostgreSQL 用 `$n`（从 `startIndex + 1` 起编号，
    /// 以便与既有筛选参数拼接），MySQL/SQLite 用 `?`。
    /// term 为空或无可搜索列时返回 nil。
    public static func serverWhere(
        columns: [TableColumn],
        term: String,
        dialect: DatabaseType,
        startIndex: Int = 0,
        quote: (String) -> String
    ) -> (clause: String, params: [DatabaseValue])? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let searchable = columns.filter { CellColumnTypeFamily(dataType: $0.dataType) != .binary }
        guard !searchable.isEmpty else { return nil }
        let pattern = "%" + escapeLike(trimmed) + "%"
        var params: [DatabaseValue] = []
        var fragments: [String] = []
        for (i, col) in searchable.enumerated() {
            let placeholder = dialect == .postgresql ? "$\(startIndex + i + 1)" : "?"
            fragments.append("\(loweredColumn(quote(col.name), dataType: col.dataType, dialect: dialect)) LIKE LOWER(\(placeholder)) ESCAPE '!'")
            params.append(.string(pattern))
        }
        return ("(" + fragments.joined(separator: " OR ") + ")", params)
    }

    /// 列的小写表达式。PostgreSQL 的 LOWER 不接受非文本参数（无隐式转换），
    /// 数值/日期等列须先 CAST AS text；MySQL/SQLite 会隐式转换，直接 LOWER。
    private static func loweredColumn(_ quoted: String, dataType: String, dialect: DatabaseType) -> String {
        if dialect == .postgresql, CellColumnTypeFamily(dataType: dataType) != .text {
            return "LOWER(CAST(\(quoted) AS text))"
        }
        return "LOWER(\(quoted))"
    }

    /// LIKE 通配符转义（`!` 为转义符，与筛选构建器一致）。
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
    }
}