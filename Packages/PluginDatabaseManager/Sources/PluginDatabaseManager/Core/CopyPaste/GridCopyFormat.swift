import Foundation

/// 行级复制格式（右键菜单用，作用于被右键的行）。
public enum GridRowCopyKind: Sendable {
    case json, csv, insert, update
}

/// 页级复制格式（Edit 菜单 / 行菜单用，作用于当前页全部行）。
public enum GridPageCopyKind: Sendable {
    case csv, markdown
}

/// 数据网格的复制序列化（纯函数，不依赖连接）。
///
/// - JSON：列名 → 值；NULL → null，BLOB → `0x` hex 文本（与单元格 hex 编辑往返一致）；
/// - CSV：RFC 4180（含逗号/引号/换行的字段加引号，引号翻倍），NULL → 空字段；
/// - SQL：标识符按方言引号转义，值走 ``sqlLiteral(for:dialect:)``（绝不内插用户文本）。
public enum GridCopyFormat {
    // MARK: - JSON

    public static func rowJSON(columns: [String], row: [DatabaseValue]) -> String {
        var object: [String: Any] = [:]
        for (index, column) in columns.enumerated() where index < row.count {
            object[column] = jsonValue(row[index])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func jsonValue(_ value: DatabaseValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .integer(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .string(let s): return s
        case .data(let data): return "0x" + data.map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - CSV

    public static func rowCSV(columns: [String], row: [DatabaseValue]) -> String {
        columns.indices.map { index in
            csvField(index < row.count ? csvText(row[index]) : "")
        }
        .joined(separator: ",")
    }

    public static func csvWithHeaders(columns: [String], rows: [[DatabaseValue]]) -> String {
        var lines = [columns.map(csvField).joined(separator: ",")]
        for row in rows {
            lines.append(rowCSV(columns: columns, row: row))
        }
        return lines.joined(separator: "\r\n")
    }

    /// NULL → 空字段；BLOB → 0x hex（可被粘贴解析还原）。
    private static func csvText(_ value: DatabaseValue) -> String {
        switch value {
        case .null: return ""
        case .data(let data): return "0x" + data.map { String(format: "%02x", $0) }.joined()
        default: return String(describing: value)
        }
    }

    private static func csvField(_ text: String) -> String {
        if text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r") {
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }

    // MARK: - Markdown

    public static func markdownTable(columns: [String], rows: [[DatabaseValue]]) -> String {
        var lines = [
            "| " + columns.map(markdownCell).joined(separator: " | ") + " |",
            "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |"
        ]
        for row in rows {
            lines.append(rowMarkdown(columns: columns, row: row))
        }
        return lines.joined(separator: "\n")
    }

    /// 单行 Markdown 表格行（流式导出用，与 ``markdownTable(columns:rows:)`` 逐行一致）。
    public static func rowMarkdown(columns: [String], row: [DatabaseValue]) -> String {
        let cells = columns.indices.map { index in
            markdownCell(index < row.count ? markdownText(row[index]) : "")
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private static func markdownText(_ value: DatabaseValue) -> String {
        switch value {
        case .null: return "NULL"
        case .data(let data): return "<BLOB \(data.count) bytes>"
        default: return String(describing: value)
        }
    }

    private static func markdownCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    // MARK: - SQL

    /// `tableExpr` 为已按方言限定并引号化的表名（如 `"public"."t"`），不再二次引号化。
    public static func insertSQL(tableExpr: String, columns: [String], row: [DatabaseValue], dialect: DatabaseType) -> String {
        let cols = columns.map { quote($0, dialect) }.joined(separator: ", ")
        let values = columns.indices.map { index in
            sqlLiteral(for: index < row.count ? row[index] : .null, dialect: dialect)
        }
        .joined(separator: ", ")
        return "INSERT INTO \(tableExpr) (\(cols)) VALUES (\(values));"
    }

    /// UPDATE 语句：SET 全部非键列，WHERE 键列精确匹配。
    /// 无键列、键列缺失或无非键列时返回 nil（无法安全定位）。
    public static func updateSQL(
        tableExpr: String,
        columns: [String],
        row: [DatabaseValue],
        keyColumns: [String],
        dialect: DatabaseType
    ) -> String? {
        guard !keyColumns.isEmpty else { return nil }
        let keySet = Set(keyColumns)
        guard keySet.allSatisfy({ columns.contains($0) }) else { return nil }
        let nonKeys = columns.filter { !keySet.contains($0) }
        guard !nonKeys.isEmpty else { return nil }
        func value(of column: String) -> DatabaseValue {
            guard let index = columns.firstIndex(of: column), index < row.count else { return .null }
            return row[index]
        }
        let setClause = nonKeys
            .map { "\(quote($0, dialect)) = \(sqlLiteral(for: value(of: $0), dialect: dialect))" }
            .joined(separator: ", ")
        let whereClause = keyColumns
            .map { "\(quote($0, dialect)) = \(sqlLiteral(for: value(of: $0), dialect: dialect))" }
            .joined(separator: " AND ")
        return "UPDATE \(tableExpr) SET \(setClause) WHERE \(whereClause);"
    }

    /// 当前页某列全部值的 IN 列表：去重、跳过 NULL；无值返回 nil。
    public static func inList(column: String, columns: [String], rows: [[DatabaseValue]], dialect: DatabaseType) -> String? {
        guard let index = columns.firstIndex(of: column) else { return nil }
        var seen: [DatabaseValue] = []
        for row in rows where index < row.count {
            let value = row[index]
            if value == .null || seen.contains(value) { continue }
            seen.append(value)
        }
        guard !seen.isEmpty else { return nil }
        return "(" + seen.map { sqlLiteral(for: $0, dialect: dialect) }.joined(separator: ", ") + ")"
    }

    // MARK: - Helpers

    private static func quote(_ name: String, _ dialect: DatabaseType) -> String {
        guard let q = dialect.capabilities.identifierQuoteCharacter else { return name }
        let escaped = name.replacingOccurrences(of: String(q), with: String(q) + String(q))
        return "\(q)\(escaped)\(q)"
    }
}