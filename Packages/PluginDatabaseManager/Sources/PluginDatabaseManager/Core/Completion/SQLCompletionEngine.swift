import Foundation

// MARK: - 补全元数据（值类型，可离线测试）

/// 补全用的一列。
public struct SQLCompletionColumn: Hashable, Sendable {
    public let name: String
    public let dataType: String
    public let isPrimaryKey: Bool

    public init(name: String, dataType: String, isPrimaryKey: Bool = false) {
        self.name = name
        self.dataType = dataType
        self.isPrimaryKey = isPrimaryKey
    }
}

/// 补全用的一张表（含列）。
public struct SQLCompletionTable: Hashable, Sendable {
    public let name: String
    public let schema: String?
    public let columns: [SQLCompletionColumn]

    public init(name: String, schema: String? = nil, columns: [SQLCompletionColumn] = []) {
        self.name = name
        self.schema = schema
        self.columns = columns
    }
}

/// 一个连接的补全元数据快照。
public struct SQLCompletionMetadata: Sendable {
    public let tables: [SQLCompletionTable]
    public let schemas: [String]

    public init(tables: [SQLCompletionTable], schemas: [String] = []) {
        self.tables = tables
        self.schemas = schemas
    }

    public static let empty = SQLCompletionMetadata(tables: [], schemas: [])
}

/// 一条补全候选。
public struct SQLCompletionCandidate: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case keyword, table, column, schema, alias
    }

    public let label: String
    public let insertText: String
    public let detail: String?
    public let kind: Kind
    public let priority: Int

    public init(label: String, insertText: String? = nil, detail: String? = nil, kind: Kind, priority: Int = 0) {
        self.label = label
        self.insertText = insertText ?? label
        self.detail = detail
        self.kind = kind
        self.priority = priority
    }
}

// MARK: - 引擎

/// 纯逻辑 SQL 补全引擎：给定文档文本 + 光标 UTF-16 偏移 + 连接元数据，产出排序后的候选。
///
/// 不依赖 UI / 连接 / 异步，便于单元测试。覆盖：关键字、表、列（限定名）、schema、
/// 简单别名（`FROM t [AS] a` / `JOIN t [AS] a`）。JOIN/CTE 复杂别名解析为二期。
public enum SQLCompletionEngine {

    /// 光标处的补全上下文。
    public struct Context: Sendable {
        /// 正在输入的标识符前缀（可能为空）。
        public let prefix: String
        /// 应用补全时应替换的 UTF-16 范围（仅前缀本身，保留限定符与点）。
        public let replacementRange: NSRange
        /// 紧邻前缀点号前的限定符（别名 / 表名 / schema名），无则 nil。
        public let qualifier: String?
        /// 二级限定符（`schema.table.` 中的 schema），无则 nil。
        public let schemaQualifier: String?
    }

    private static let identifierSet: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_$")
        return set
    }()

    private static func isIdentifierUnit(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return identifierSet.contains(scalar)
    }

    /// 解析光标处的补全上下文（前缀 / 替换范围 / 限定符）。
    public static func context(in text: String, utf16Offset: Int) -> Context {
        let ns = text as NSString
        let length = ns.length
        let offset = max(0, min(utf16Offset, length))
        let dot = unichar(46) // '.'

        var start = offset
        while start > 0, isIdentifierUnit(ns.character(at: start - 1)) { start -= 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: offset - start))

        var qualifier: String?
        var schemaQualifier: String?
        if start > 0, ns.character(at: start - 1) == dot {
            let qEnd = start - 1
            var qStart = qEnd
            while qStart > 0, isIdentifierUnit(ns.character(at: qStart - 1)) { qStart -= 1 }
            if qStart < qEnd {
                qualifier = ns.substring(with: NSRange(location: qStart, length: qEnd - qStart))
            }
            if qStart > 0, ns.character(at: qStart - 1) == dot {
                let sEnd = qStart - 1
                var sStart = sEnd
                while sStart > 0, isIdentifierUnit(ns.character(at: sStart - 1)) { sStart -= 1 }
                if sStart < sEnd {
                    schemaQualifier = ns.substring(with: NSRange(location: sStart, length: sEnd - sStart))
                }
            }
        }

        return Context(
            prefix: prefix,
            replacementRange: NSRange(location: start, length: offset - start),
            qualifier: qualifier,
            schemaQualifier: schemaQualifier
        )
    }

    /// 生成候选。`limit` 截断最终结果数量。
    public static func candidates(
        in text: String,
        utf16Offset: Int,
        metadata: SQLCompletionMetadata,
        dialect: DatabaseType,
        limit: Int = 60
    ) -> [SQLCompletionCandidate] {
        let ctx = context(in: text, utf16Offset: utf16Offset)
        let prefixLower = ctx.prefix.lowercased()
        let aliases = aliasContext(in: text)

        if let qualifier = ctx.qualifier {
            return qualifiedCandidates(
                qualifier: qualifier,
                schemaQualifier: ctx.schemaQualifier,
                prefix: ctx.prefix,
                prefixLower: prefixLower,
                metadata: metadata,
                aliases: aliases,
                limit: limit
            )
        }

        let category = expectedCategory(in: text, before: ctx.replacementRange.location)
        var raw: [SQLCompletionCandidate] = []

        // 关键字
        for keyword in keywords {
            guard matches(keyword.lowercased(), prefixLower) else { continue }
            raw.append(SQLCompletionCandidate(
                label: keyword,
                insertText: keyword,
                detail: nil,
                kind: .keyword,
                priority: 10
            ))
        }

        // 表
        for table in metadata.tables {
            guard matches(table.name.lowercased(), prefixLower) else { continue }
            let boost = category == .table ? 40 : 0
            raw.append(SQLCompletionCandidate(
                label: table.name,
                insertText: followCase(table.name, prefix: ctx.prefix),
                detail: table.schema.map { "\($0) · table" } ?? "table",
                kind: .table,
                priority: 20 + boost
            ))
        }

        // schema
        for schema in metadata.schemas {
            guard matches(schema.lowercased(), prefixLower) else { continue }
            let boost = category == .table ? 20 : 0
            raw.append(SQLCompletionCandidate(
                label: schema,
                insertText: followCase(schema, prefix: ctx.prefix),
                detail: "schema",
                kind: .schema,
                priority: 15 + boost
            ))
        }

        // 列：优先来自语句引用的表；无引用时给全部表的列。
        let columnTables = referencedTables(aliases: aliases, metadata: metadata)
        let qualifyColumns = columnTables.count > 1
        for table in columnTables {
            for column in table.columns {
                guard matches(column.name.lowercased(), prefixLower) else { continue }
                let boost = category == .column ? 40 : 0
                let label = qualifyColumns ? "\(table.name).\(column.name)" : column.name
                let insert = qualifyColumns
                    ? "\(followCase(table.name, prefix: ctx.prefix)).\(followCase(column.name, prefix: ctx.prefix))"
                    : followCase(column.name, prefix: ctx.prefix)
                var detail = "\(table.name) · \(column.dataType)"
                if column.isPrimaryKey { detail += " · PK" }
                raw.append(SQLCompletionCandidate(
                    label: label,
                    insertText: insert,
                    detail: detail,
                    kind: .column,
                    priority: 30 + boost
                ))
            }
        }

        return ranked(raw, prefix: ctx.prefix, prefixLower: prefixLower, limit: limit)
    }

    // MARK: - 限定名候选

    private static func qualifiedCandidates(
        qualifier: String,
        schemaQualifier: String?,
        prefix: String,
        prefixLower: String,
        metadata: SQLCompletionMetadata,
        aliases: AliasContext,
        limit: Int
    ) -> [SQLCompletionCandidate] {
        let qLower = qualifier.lowercased()
        // 别名优先解析到真实表名（`FROM users u` → `u.` 命中 users）。
        let resolvedName = aliases.aliasToTable[qLower] ?? qLower

        // schema 限定：`public.` → 该 schema 下的表。
        if schemaQualifier == nil,
           metadata.schemas.contains(where: { $0.lowercased() == qLower }),
           !metadata.tables.contains(where: { $0.name.lowercased() == resolvedName }) {
            let tables = metadata.tables.filter { ($0.schema ?? "").lowercased() == qLower }
            let raw = tables.compactMap { table -> SQLCompletionCandidate? in
                guard matches(table.name.lowercased(), prefixLower) else { return nil }
                return SQLCompletionCandidate(
                    label: table.name,
                    insertText: followCase(table.name, prefix: prefix),
                    detail: "\(qualifier) · table",
                    kind: .table,
                    priority: 60
                )
            }
            return ranked(raw, prefix: prefix, prefixLower: prefixLower, limit: limit)
        }

        // 表/别名限定：解析到具体表后给列。
        guard let table = resolveTable(qualifier: resolvedName, schemaQualifier: schemaQualifier, metadata: metadata) else {
            return []
        }
        let raw = table.columns.compactMap { column -> SQLCompletionCandidate? in
            guard matches(column.name.lowercased(), prefixLower) else { return nil }
            var detail = "\(table.name) · \(column.dataType)"
            if column.isPrimaryKey { detail += " · PK" }
            return SQLCompletionCandidate(
                label: column.name,
                insertText: followCase(column.name, prefix: prefix),
                detail: detail,
                kind: .column,
                priority: 70 + (column.isPrimaryKey ? 5 : 0)
            )
        }
        return ranked(raw, prefix: prefix, prefixLower: prefixLower, limit: limit)
    }

    private static func resolveTable(
        qualifier: String,
        schemaQualifier: String?,
        metadata: SQLCompletionMetadata
    ) -> SQLCompletionTable? {
        // 先按表名（可带 schema）匹配。
        if let schemaQualifier {
            let sLower = schemaQualifier.lowercased()
            if let t = metadata.tables.first(where: { $0.name.lowercased() == qualifier && ($0.schema ?? "").lowercased() == sLower }) {
                return t
            }
        }
        if let t = metadata.tables.first(where: { $0.name.lowercased() == qualifier }) {
            return t
        }
        return nil
    }

    // MARK: - 别名 / 引用表

    struct AliasContext {
        var aliasToTable: [String: String] = [:]
        var referenced: [String] = []
    }

    private static let aliasBlocklist: Set<String> = [
        "WHERE", "ON", "USING", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "FULL",
        "GROUP", "ORDER", "LIMIT", "OFFSET", "HAVING", "UNION", "SET", "VALUES", "SELECT",
        "AS", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "WHEN", "THEN",
        "ELSE", "END", "ASC", "DESC", "RETURNING", "WINDOW", "FETCH", "FOR", "WITH"
    ]

    /// 从文本中解析简单别名与引用表（在剥离字符串/注释后的文本上做正则）。
    static func aliasContext(in text: String) -> AliasContext {
        var result = AliasContext()
        let stripped = SQLStatementParser.stripLiteralsAndComments(text)
        let pattern = "(?:FROM|JOIN)\\s+([A-Za-z_][\\w$]*(?:\\.[A-Za-z_][\\w$]*)?)(?:\\s+(?:AS\\s+)?([A-Za-z_][\\w$]*))?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return result }
        let ns = stripped as NSString
        let matches = regex.matches(in: stripped, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let tableRange = match.range(at: 1)
            guard tableRange.location != NSNotFound else { continue }
            let fullTable = ns.substring(with: tableRange)
            let tableName = fullTable.components(separatedBy: ".").last ?? fullTable
            let tableLower = tableName.lowercased()
            if !result.referenced.contains(tableLower) {
                result.referenced.append(tableLower)
            }
            if match.numberOfRanges >= 3 {
                let aliasRange = match.range(at: 2)
                if aliasRange.location != NSNotFound {
                    let alias = ns.substring(with: aliasRange)
                    if !aliasBlocklist.contains(alias.uppercased()) {
                        result.aliasToTable[alias.lowercased()] = tableLower
                    }
                }
            }
        }
        return result
    }

    private static func referencedTables(aliases: AliasContext, metadata: SQLCompletionMetadata) -> [SQLCompletionTable] {
        guard !aliases.referenced.isEmpty else { return metadata.tables }
        var seen = Set<String>()
        var tables: [SQLCompletionTable] = []
        for name in aliases.referenced {
            let resolved = aliases.aliasToTable[name] ?? name
            guard !seen.contains(resolved) else { continue }
            if let table = metadata.tables.first(where: { $0.name.lowercased() == resolved }) {
                seen.insert(resolved)
                tables.append(table)
            }
        }
        return tables.isEmpty ? metadata.tables : tables
    }

    // MARK: - 上下文类别

    enum Category { case table, column, general }

    private static let tableKeywords: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "EXISTS", "ONLY"]
    private static let columnKeywords: Set<String> = [
        "SELECT", "WHERE", "AND", "OR", "ON", "BY", "HAVING", "SET", "WHEN", "THEN",
        "ELSE", "DISTINCT", "ALL", "ASC", "DESC", "BETWEEN", "LIKE", "IN", "IS", "NOT"
    ]

    /// 看前缀之前最近的一个关键字，判断当前期望表名还是列名。
    static func expectedCategory(in text: String, before offset: Int) -> Category {
        let ns = text as NSString
        var i = max(0, min(offset, ns.length))
        // 跳过空白
        while i > 0, isWhitespace(ns.character(at: i - 1)) { i -= 1 }
        // 读上一个标识符词
        var end = i
        while i > 0, isIdentifierUnit(ns.character(at: i - 1)) { i -= 1 }
        if i < end {
            let word = ns.substring(with: NSRange(location: i, length: end - i)).uppercased()
            if tableKeywords.contains(word) { return .table }
            if columnKeywords.contains(word) { return .column }
            return .general
        }
        // 非标识符（如 ',' '(' '='）→ 列上下文
        if end > 0 {
            let ch = ns.character(at: end - 1)
            if ch == unichar(44) || ch == unichar(40) || ch == unichar(61) { return .column }
        }
        return .general
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13
    }

    // MARK: - 匹配 / 排序 / 大小写

    private static func matches(_ candidateLower: String, _ prefixLower: String) -> Bool {
        prefixLower.isEmpty || candidateLower.hasPrefix(prefixLower) || candidateLower.contains(prefixLower)
    }

    private static func matchQuality(_ label: String, prefix: String, prefixLower: String) -> Int {
        if prefix.isEmpty { return 2 }
        if label.hasPrefix(prefix) { return 3 }
        if label.lowercased().hasPrefix(prefixLower) { return 2 }
        return 1
    }

    private static func ranked(_ candidates: [SQLCompletionCandidate], prefix: String, prefixLower: String, limit: Int) -> [SQLCompletionCandidate] {
        // 去重（同 label+kind）。
        var seen = Set<String>()
        var unique: [SQLCompletionCandidate] = []
        for c in candidates {
            let key = "\(c.kind.rawValue):\(c.label.lowercased())"
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(c)
        }
        let sorted = unique.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let qa = matchQuality(a.label, prefix: prefix, prefixLower: prefixLower)
            let qb = matchQuality(b.label, prefix: prefix, prefixLower: prefixLower)
            if qa != qb { return qa > qb }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// 标识符大小写跟随已输入前缀的习惯：全小写→小写，全大写→大写，否则保留元数据原样。
    static func followCase(_ identifier: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return identifier }
        if prefix == prefix.lowercased() { return identifier.lowercased() }
        if prefix == prefix.uppercased() { return identifier.uppercased() }
        return identifier
    }

    /// 常用 SQL 关键字（大写规范形）。
    public static let keywords: [String] = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON", "AS",
        "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "EXISTS",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "DISTINCT", "ALL",
        "ASC", "DESC", "UNION", "INTERSECT", "EXCEPT", "CASE", "WHEN", "THEN", "ELSE", "END",
        "COUNT", "SUM", "AVG", "MIN", "MAX", "CAST", "COALESCE", "NULLIF",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "DEFAULT", "CHECK", "CONSTRAINT",
        "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION", "WITH", "RECURSIVE", "RETURNING",
        "EXPLAIN", "ANALYZE", "PRAGMA", "SHOW", "DESCRIBE", "TRUNCATE", "GRANT", "REVOKE"
    ]
}