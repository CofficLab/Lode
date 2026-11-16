import Foundation

/// 筛选运算符集（SQL 引擎专用；Redis 走键浏览，不适用）。
public enum FilterOperator: String, CaseIterable, Sendable, Identifiable {
    case equals = "="
    case notEquals = "!="
    case greaterThan = ">"
    case greaterOrEqual = ">="
    case lessThan = "<"
    case lessOrEqual = "<="
    case contains
    case notContains
    case startsWith
    case endsWith
    case between
    case inList = "in"
    case notInList = "notIn"
    case isNull
    case isNotNull
    case isEmpty
    case isNotEmpty
    case regex

    public var id: String { rawValue }

    /// 操作数形态：无操作数 / 单值 / 双值（between）/ 列表（in/notIn）。
    public enum OperandKind: Sendable {
        case none, single, pair, list
    }

    public var operandKind: OperandKind {
        switch self {
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty:
            return .none
        case .between:
            return .pair
        case .inList, .notInList:
            return .list
        default:
            return .single
        }
    }

    /// 是否为文本模式匹配类（LIKE/REGEX），操作数恒按字符串绑定。
    var isTextPattern: Bool {
        switch self {
        case .contains, .notContains, .startsWith, .endsWith, .regex:
            return true
        default:
            return false
        }
    }

    public var displayTitle: String {
        switch self {
        case .equals: return "="
        case .notEquals: return "!="
        case .greaterThan: return ">"
        case .greaterOrEqual: return ">="
        case .lessThan: return "<"
        case .lessOrEqual: return "<="
        case .contains: return pluginLocalization.string("Contains")
        case .notContains: return pluginLocalization.string("Not Contains")
        case .startsWith: return pluginLocalization.string("Starts With")
        case .endsWith: return pluginLocalization.string("Ends With")
        case .between: return pluginLocalization.string("Between")
        case .inList: return pluginLocalization.string("In")
        case .notInList: return pluginLocalization.string("Not In")
        case .isNull: return pluginLocalization.string("Is NULL")
        case .isNotNull: return pluginLocalization.string("Is Not NULL")
        case .isEmpty: return pluginLocalization.string("Is Empty")
        case .isNotEmpty: return pluginLocalization.string("Is Not Empty")
        case .regex: return pluginLocalization.string("Regex")
        }
    }

    /// 该运算符在指定方言下是否可用。SQL 三引擎均支持全部运算符
    /// （SQLite 的 REGEXP 由驱动注册）；Redis 不适用筛选。
    public func isAvailable(for dialect: DatabaseType) -> Bool {
        dialect != .redis
    }
}

/// 一条筛选条件：列 + 运算符 + 操作数 + 启用开关 + 大小写敏感。
public struct FilterCondition: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var column: String
    public var op: FilterOperator
    /// 操作数文本：单值用 [0]，between 用 [0]/[1]，in/notIn 用全部。
    public var operands: [String]
    public var isEnabled: Bool
    public var caseSensitive: Bool

    public init(
        id: UUID = UUID(),
        column: String,
        op: FilterOperator = .equals,
        operands: [String] = [""],
        isEnabled: Bool = true,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.column = column
        self.op = op
        self.operands = operands
        self.isEnabled = isEnabled
        self.caseSensitive = caseSensitive
    }

    /// 是否已填写完整、可参与 WHERE 生成（启用 + 有列名 + 操作数充足）。
    /// 空操作数视为「尚未填写」，不产生过滤；过滤空串请用 Is Empty 运算符。
    public var isComplete: Bool {
        guard isEnabled, !column.isEmpty else { return false }
        switch op.operandKind {
        case .none:
            return true
        case .single:
            return !(operands.first ?? "").isEmpty
        case .pair:
            return operands.count >= 2 && !operands[0].isEmpty && !operands[1].isEmpty
        case .list:
            return operands.contains { !$0.isEmpty }
        }
    }
}

/// 表筛选模型：一组 AND 组合的条件，或高级 raw WHERE 模式。
///
/// 生成参数化 WHERE（值绝不内插进 SQL，防注入）；占位符按方言选择
/// （SQLite/MySQL 用 `?`，PostgreSQL 用 `$n`）。操作数按列类型绑定，
/// 使 PostgreSQL 上数值列的比较不会因 text 绑定而报类型错误。
public struct TableFilter: Sendable, Equatable {
    public var conditions: [FilterCondition]
    public var useRawWhere: Bool
    public var rawWhere: String

    public init(conditions: [FilterCondition] = [], useRawWhere: Bool = false, rawWhere: String = "") {
        self.conditions = conditions
        self.useRawWhere = useRawWhere
        self.rawWhere = rawWhere
    }

    public static let empty = TableFilter()

    /// 已填写完整且启用的条件。
    public var activeConditions: [FilterCondition] { conditions.filter(\.isComplete) }

    /// 当前是否会产生过滤效果。
    public var isActive: Bool {
        if useRawWhere {
            return !rawWhere.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !activeConditions.isEmpty
    }

    /// 生成 WHERE 子句（不含 `WHERE` 关键字）与绑定参数；无有效条件返回 nil。
    public func buildWhere(dialect: DatabaseType, columns: [TableColumn] = []) -> (clause: String, params: [DatabaseValue])? {
        if useRawWhere {
            let trimmed = rawWhere.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (trimmed, [])
        }
        let active = activeConditions
        guard !active.isEmpty else { return nil }
        var params: [DatabaseValue] = []
        var index = 0
        let clause = render(active, dialect: dialect, columns: columns) { value in
            params.append(value)
            index += 1
            return dialect == .postgresql ? "$\(index)" : "?"
        }
        return (clause, params)
    }

    /// WHERE 预览（含 `WHERE` 关键字，参数以字面量内联展示，仅供 UI 显示）。
    public func previewWhere(dialect: DatabaseType, columns: [TableColumn] = []) -> String? {
        if useRawWhere {
            let trimmed = rawWhere.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "WHERE " + trimmed
        }
        let active = activeConditions
        guard !active.isEmpty else { return nil }
        let clause = render(active, dialect: dialect, columns: columns) { value in
            sqlLiteral(for: value, dialect: dialect)
        }
        return "WHERE " + clause
    }

    // MARK: - 渲染

    private func render(
        _ conditions: [FilterCondition],
        dialect: DatabaseType,
        columns: [TableColumn],
        emit: (DatabaseValue) -> String
    ) -> String {
        conditions.map { condition in
            let col = Self.quote(condition.column, dialect)
            let type = columns.first { $0.name == condition.column }?.dataType
            return Self.fragment(condition, column: col, columnType: type, dialect: dialect, emit: emit)
        }
        .joined(separator: " AND ")
    }

    private static func fragment(
        _ c: FilterCondition,
        column col: String,
        columnType: String?,
        dialect: DatabaseType,
        emit: (DatabaseValue) -> String
    ) -> String {
        // 文本模式匹配恒按字符串绑定；其余按列类型绑定（数值/布尔列正确比较）。
        func bound(_ s: String) -> String {
            emit(c.op.isTextPattern ? .string(s) : typedOperand(s, columnType: columnType))
        }
        let values = c.operands
        switch c.op {
        case .equals:
            return "\(col) = \(bound(values[0]))"
        case .notEquals:
            return "\(col) <> \(bound(values[0]))"
        case .greaterThan:
            return "\(col) > \(bound(values[0]))"
        case .greaterOrEqual:
            return "\(col) >= \(bound(values[0]))"
        case .lessThan:
            return "\(col) < \(bound(values[0]))"
        case .lessOrEqual:
            return "\(col) <= \(bound(values[0]))"
        case .contains:
            return likeFragment(col, pattern: "%" + escapeLike(values[0]) + "%", negate: false, caseSensitive: c.caseSensitive, dialect: dialect, emit: emit)
        case .notContains:
            return likeFragment(col, pattern: "%" + escapeLike(values[0]) + "%", negate: true, caseSensitive: c.caseSensitive, dialect: dialect, emit: emit)
        case .startsWith:
            return likeFragment(col, pattern: escapeLike(values[0]) + "%", negate: false, caseSensitive: c.caseSensitive, dialect: dialect, emit: emit)
        case .endsWith:
            return likeFragment(col, pattern: "%" + escapeLike(values[0]), negate: false, caseSensitive: c.caseSensitive, dialect: dialect, emit: emit)
        case .between:
            return "\(col) BETWEEN \(bound(values[0])) AND \(bound(values[1]))"
        case .inList:
            return "\(col) IN (\(listValues(values, bound: bound)))"
        case .notInList:
            return "\(col) NOT IN (\(listValues(values, bound: bound)))"
        case .isNull:
            return "\(col) IS NULL"
        case .isNotNull:
            return "\(col) IS NOT NULL"
        case .isEmpty:
            return "\(col) = ''"
        case .isNotEmpty:
            return "\(col) <> ''"
        case .regex:
            return regexFragment(col, pattern: values[0], dialect: dialect, caseSensitive: c.caseSensitive, emit: emit)
        }
    }

    private static func listValues(_ values: [String], bound: (String) -> String) -> String {
        values.filter { !$0.isEmpty }.map(bound).joined(separator: ", ")
    }

    /// LIKE 片段。大小写不敏感时两侧套 LOWER（三引擎通用）。
    /// 敏感时各引擎方言不同：PG 裸 LIKE 即敏感；MySQL 默认排序规则不敏感，
    /// 需 CAST AS BINARY 逐字节比较；SQLite LIKE 对 ASCII 不敏感，改用大小写敏感的 GLOB。
    /// 转义符用 `!`（避免 MySQL 反斜杠字符串转义歧义）。
    private static func likeFragment(
        _ col: String,
        pattern: String,
        negate: Bool,
        caseSensitive: Bool,
        dialect: DatabaseType,
        emit: (DatabaseValue) -> String
    ) -> String {
        let likeOp = negate ? "NOT LIKE" : "LIKE"
        if caseSensitive {
            switch dialect {
            case .mysql:
                return "CAST(\(col) AS BINARY) \(likeOp) \(emit(.string(pattern))) ESCAPE '!'"
            case .sqlite:
                let globOp = negate ? "NOT GLOB" : "GLOB"
                return "\(col) \(globOp) \(emit(.string(likePatternToGlob(pattern))))"
            default:
                return "\(col) \(likeOp) \(emit(.string(pattern))) ESCAPE '!'"
            }
        }
        return "LOWER(\(col)) \(likeOp) LOWER(\(emit(.string(pattern)))) ESCAPE '!'"
    }

    /// 把 LIKE 模式（`!` 转义、`%`/`_` 通配）转成 GLOB 模式（`*`/`?` 通配、大小写敏感）。
    /// GLOB 无转义符，字面 `* ? [ ]` 用单字符括号表达式包裹。
    private static func likePatternToGlob(_ pattern: String) -> String {
        let chars = Array(pattern)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "!", i + 1 < chars.count {
                out += globLiteral(chars[i + 1])
                i += 2
                continue
            }
            switch ch {
            case "%": out += "*"
            case "_": out += "?"
            default: out += globLiteral(ch)
            }
            i += 1
        }
        return out
    }

    private static func globLiteral(_ ch: Character) -> String {
        switch ch {
        case "*", "?", "[", "]": return "[\(ch)]"
        default: return String(ch)
        }
    }

    /// REGEX 片段：PG 用 `~`/`~*`，MySQL 用 REGEXP_LIKE（'c'/'i' 匹配类型），
    /// SQLite 用驱动注册的 REGEXP（大小写不敏感）。
    private static func regexFragment(
        _ col: String,
        pattern: String,
        dialect: DatabaseType,
        caseSensitive: Bool,
        emit: (DatabaseValue) -> String
    ) -> String {
        let placeholder = emit(.string(pattern))
        switch dialect {
        case .postgresql:
            return "\(col) \(caseSensitive ? "~" : "~*") \(placeholder)"
        case .mysql:
            return "REGEXP_LIKE(\(col), \(placeholder), '\(caseSensitive ? "c" : "i")')"
        case .sqlite:
            return "\(col) REGEXP \(placeholder)"
        case .redis:
            return "\(col) = \(placeholder)"
        }
    }

    /// LIKE 通配符转义（`!` 为转义符）。
    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
    }

    /// 按列类型把操作数文本转成绑定值（数值/布尔列正确类型，其余字符串）。
    static func typedOperand(_ s: String, columnType: String?) -> DatabaseValue {
        switch CellColumnTypeFamily(dataType: columnType ?? "") {
        case .integer:
            if let i = Int(s) { return .integer(i) }
            return .string(s)
        case .real:
            if let d = Double(s) { return .double(d) }
            return .string(s)
        case .boolean:
            switch s.lowercased() {
            case "true", "t", "yes", "y", "1": return .bool(true)
            case "false", "f", "no", "n", "0": return .bool(false)
            default: return .string(s)
            }
        default:
            return .string(s)
        }
    }

    private static func quote(_ name: String, _ dialect: DatabaseType) -> String {
        guard let q = dialect.capabilities.identifierQuoteCharacter else { return name }
        let escaped = name.replacingOccurrences(of: String(q), with: String(q) + String(q))
        return "\(q)\(escaped)\(q)"
    }
}