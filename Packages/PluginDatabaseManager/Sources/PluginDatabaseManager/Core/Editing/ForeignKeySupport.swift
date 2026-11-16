import Foundation

/// 外键引用选择器的一个候选项：键值 + 其余列的预览文本。
public struct FKReferenceOption: Sendable, Equatable {
    public let keyValue: DatabaseValue
    public let preview: String

    public init(keyValue: DatabaseValue, preview: String) {
        self.keyValue = keyValue
        self.preview = preview
    }
}

/// 外键取值与引用行定位的纯逻辑（SQL 生成不依赖连接，便于单测）。
///
/// - 选值：仅单列外键支持（复合键无法用单个单元格值表达）；
/// - 定位：把当前行的外键值转成引用表上的 raw WHERE 过滤，复用表浏览管线；
/// - 搜索：在引用表的非二进制列上做参数化 LIKE（值绝不内插进 SQL）。
public enum ForeignKeySupport {
    /// 列参与的外键（取第一个包含该列的定义）。
    public static func foreignKey(for column: String, in schema: TableSchema) -> ForeignKey? {
        schema.foreignKeys.first { $0.columns.contains(column) }
    }

    /// 是否可用单元格选择器选值：单列 → 单列引用。
    public static func canPick(_ fk: ForeignKey) -> Bool {
        fk.columns.count == 1 && fk.referencesColumns.count == 1 && !fk.referencesTable.isEmpty
    }

    /// 按外键列顺序取当前行的值；任一列缺失返回 nil。
    public static func sourceValues(_ fk: ForeignKey, rowValues: [DatabaseValue], columns: [String]) -> [DatabaseValue]? {
        var values: [DatabaseValue] = []
        for column in fk.columns {
            guard let idx = columns.firstIndex(of: column), idx < rowValues.count else { return nil }
            values.append(rowValues[idx])
        }
        return values
    }

    /// 这组外键值能否定位引用行：列数对齐、无 NULL / BLOB。
    public static func canLocate(_ fk: ForeignKey, values: [DatabaseValue]) -> Bool {
        guard !fk.columns.isEmpty,
              fk.columns.count == fk.referencesColumns.count,
              values.count == fk.columns.count else { return false }
        return values.allSatisfy { value in
            switch value {
            case .null, .data: return false
            default: return true
            }
        }
    }

    /// 生成定位引用行的过滤（raw WHERE，字面量按方言转义）。不可定位返回 nil。
    public static func locateFilter(_ fk: ForeignKey, values: [DatabaseValue], dialect: DatabaseType) -> TableFilter? {
        guard canLocate(fk, values: values) else { return nil }
        let clause = zip(fk.referencesColumns, values)
            .map { "\(quote($0.0, dialect)) = \(sqlLiteral(for: $0.1, dialect: dialect))" }
            .joined(separator: " AND ")
        return TableFilter(useRawWhere: true, rawWhere: clause)
    }

    /// 引用表搜索 SQL：在非二进制列上 OR LIKE，按键列排序并限量。
    ///
    /// `searchColumns` 为引用表的列（调用方从 catalog 取得）；为空时退回键列。
    /// 空搜索词返回不带 WHERE 的前 N 行。占位符 SQLite/MySQL 用 `?`，PG 用 `$n`。
    public static func referenceSearchSQL(
        _ fk: ForeignKey,
        dialect: DatabaseType,
        search: String,
        searchColumns: [TableColumn] = [],
        limit: Int = 50
    ) -> (sql: String, params: [DatabaseValue])? {
        guard canPick(fk) else { return nil }
        let keyColumn = fk.referencesColumns[0]
        let tableExpr = quote(fk.referencesTable, dialect)
        var sql = "SELECT * FROM \(tableExpr)"
        var params: [DatabaseValue] = []
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var columns = searchColumns
                .filter { CellColumnTypeFamily(dataType: $0.dataType) != .binary }
                .prefix(12)
                .map(\.name)
            if columns.isEmpty { columns = [keyColumn] }
            let pattern = "%" + escapeLike(trimmed) + "%"
            let fragments = columns.map { name -> String in
                let expr = castToText(quote(name, dialect), dialect: dialect)
                let placeholder: String
                if dialect == .postgresql {
                    params.append(.string(pattern))
                    placeholder = "$\(params.count)"
                } else {
                    params.append(.string(pattern))
                    placeholder = "?"
                }
                return "LOWER(\(expr)) LIKE LOWER(\(placeholder)) ESCAPE '!'"
            }
            sql += " WHERE " + fragments.joined(separator: " OR ")
        }
        sql += " ORDER BY \(quote(keyColumn, dialect)) ASC LIMIT \(max(1, limit))"
        return (sql, params)
    }

    /// 把查询结果转成候选项：键值取引用键列，预览取至多 3 个其余列。
    public static func options(from result: QueryResult, fk: ForeignKey) -> [FKReferenceOption] {
        guard canPick(fk),
              let keyIndex = result.columns.firstIndex(of: fk.referencesColumns[0]) else { return [] }
        let previewIndices = result.columns.indices.filter { $0 != keyIndex }.prefix(3)
        return result.rows.compactMap { row in
            guard keyIndex < row.count else { return nil }
            let preview = previewIndices.compactMap { idx -> String? in
                guard idx < row.count else { return nil }
                return "\(result.columns[idx]): \(truncate(displayText(row[idx])))"
            }
            .joined(separator: " · ")
            return FKReferenceOption(keyValue: row[keyIndex], preview: preview)
        }
    }

    // MARK: - Helpers

    /// LIKE 通配符转义（`!` 为转义符，与筛选构建器一致）。
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
    }

    static func quote(_ name: String, _ dialect: DatabaseType) -> String {
        guard let q = dialect.capabilities.identifierQuoteCharacter else { return name }
        let escaped = name.replacingOccurrences(of: String(q), with: String(q) + String(q))
        return "\(q)\(escaped)\(q)"
    }

    private static func castToText(_ expr: String, dialect: DatabaseType) -> String {
        switch dialect {
        case .mysql: return "CAST(\(expr) AS CHAR)"
        case .postgresql: return "CAST(\(expr) AS TEXT)"
        default: return expr
        }
    }

    private static func displayText(_ value: DatabaseValue) -> String {
        switch value {
        case .data(let data): return "<BLOB \(data.count) bytes>"
        default: return String(describing: value)
        }
    }

    private static func truncate(_ s: String, max: Int = 40) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }
}