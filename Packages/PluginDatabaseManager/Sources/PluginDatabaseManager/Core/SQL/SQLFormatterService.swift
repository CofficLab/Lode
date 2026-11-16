import Foundation

/// SQL 格式化选项。
public struct SQLFormatterOptions: Sendable, Equatable {
    public enum KeywordCase: Sendable, Equatable {
        case upper, lower, preserve
    }
    /// 关键字大小写（仅作用于保留关键字，标识符/字面量原样保留）。
    public var keywordCase: KeywordCase
    /// 缩进宽度（空格数）。
    public var indentWidth: Int
    /// 用制表符缩进（否则用空格）。
    public var useTabs: Bool
    /// 主要子句各占一行。
    public var clausePerLine: Bool
    /// SELECT/GROUP BY/ORDER BY 列表逐项换行。
    public var commaNewlineInList: Bool

    public init(
        keywordCase: KeywordCase = .upper,
        indentWidth: Int = 2,
        useTabs: Bool = false,
        clausePerLine: Bool = true,
        commaNewlineInList: Bool = true
    ) {
        self.keywordCase = keywordCase
        self.indentWidth = indentWidth
        self.useTabs = useTabs
        self.clausePerLine = clausePerLine
        self.commaNewlineInList = commaNewlineInList
    }
}

/// 自研规则式 SQL 格式化器（无第三方依赖）。
///
/// 设计保证：
/// - **语义不变**：只调整空白与关键字大小写，绝不改动 token 顺序、字符串字面量、
///   带引号标识符、注释内容、数字与参数；
/// - **幂等**：布局是 token 流的纯函数（不依赖原始空白），`format(format(x)) == format(x)`。
///
/// 尊重与 ``SQLStatementParser`` 一致的语法：单/双/反引号（含双写转义）、
/// 行注释与可嵌套块注释。
public enum SQLFormatterService {
    public static func format(_ sql: String, options: SQLFormatterOptions = SQLFormatterOptions()) -> String {
        let tokens = tokenize(sql)
        guard !tokens.isEmpty else { return sql.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Layout(options: options).render(tokens)
    }

    // MARK: - Tokenizer

    enum TokKind: Equatable {
        case word, number, string, quotedIdent, lineComment, blockComment, symbol, parameter
    }

    struct Tok {
        var kind: TokKind
        var text: String
    }

    static func tokenize(_ sql: String) -> [Tok] {
        let chars = Array(sql)
        let n = chars.count
        var i = 0
        var toks: [Tok] = []

        func isWordStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isWordPart(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            // 行注释
            if c == "-" && i + 1 < n && chars[i + 1] == "-" {
                var j = i
                var text = ""
                while j < n && !chars[j].isNewline { text.append(chars[j]); j += 1 }
                toks.append(Tok(kind: .lineComment, text: text))
                i = j
                continue
            }
            // 块注释（可嵌套）
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                var depth = 1
                var j = i + 2
                var text = "/*"
                while j < n && depth > 0 {
                    if chars[j] == "/" && j + 1 < n && chars[j + 1] == "*" {
                        depth += 1; text += "/*"; j += 2; continue
                    }
                    if chars[j] == "*" && j + 1 < n && chars[j + 1] == "/" {
                        depth -= 1; text += "*/"; j += 2; continue
                    }
                    text.append(chars[j]); j += 1
                }
                toks.append(Tok(kind: .blockComment, text: text))
                i = j
                continue
            }
            // 字符串 / 带引号标识符
            if c == "'" || c == "\"" || c == "`" {
                let quote = c
                var j = i + 1
                var text = String(c)
                while j < n {
                    text.append(chars[j])
                    if chars[j] == quote {
                        if j + 1 < n && chars[j + 1] == quote { text.append(chars[j + 1]); j += 2; continue }
                        j += 1; break
                    }
                    j += 1
                }
                toks.append(Tok(kind: quote == "'" ? .string : .quotedIdent, text: text))
                i = j
                continue
            }
            // ::  casts（先于参数判定）
            if c == ":" && i + 1 < n && chars[i + 1] == ":" {
                toks.append(Tok(kind: .symbol, text: "::")); i += 2; continue
            }
            // 参数 ? / :name / @name / $n
            if c == "?" {
                toks.append(Tok(kind: .parameter, text: "?")); i += 1; continue
            }
            if (c == ":" || c == "@" || c == "$") && i + 1 < n
                && (isWordStart(chars[i + 1]) || (c == "$" && chars[i + 1].isNumber)) {
                var j = i + 1
                var text = String(c)
                while j < n && isWordPart(chars[j]) { text.append(chars[j]); j += 1 }
                toks.append(Tok(kind: .parameter, text: text)); i = j; continue
            }
            // 数字
            if c.isNumber || (c == "." && i + 1 < n && chars[i + 1].isNumber) {
                if c == "0" && i + 1 < n && (chars[i + 1] == "x" || chars[i + 1] == "X") {
                    var j = i + 2
                    var text = "0x"
                    while j < n && chars[j].isHexDigit { text.append(chars[j]); j += 1 }
                    toks.append(Tok(kind: .number, text: text)); i = j; continue
                }
                var j = i
                var text = ""
                while j < n && (chars[j].isNumber || chars[j] == ".") { text.append(chars[j]); j += 1 }
                if j < n && (chars[j] == "e" || chars[j] == "E") {
                    text.append(chars[j]); j += 1
                    if j < n && (chars[j] == "+" || chars[j] == "-") { text.append(chars[j]); j += 1 }
                    while j < n && chars[j].isNumber { text.append(chars[j]); j += 1 }
                }
                toks.append(Tok(kind: .number, text: text)); i = j; continue
            }
            // 词（标识符/关键字）
            if isWordStart(c) {
                var j = i
                var text = ""
                while j < n && isWordPart(chars[j]) { text.append(chars[j]); j += 1 }
                toks.append(Tok(kind: .word, text: text)); i = j; continue
            }
            // 多字符运算符
            if i + 2 < n {
                let three = String(chars[i...(i + 2)])
                if three == "->>" || three == "#>>" {
                    toks.append(Tok(kind: .symbol, text: three)); i += 3; continue
                }
            }
            if i + 1 < n {
                let two = String(chars[i...(i + 1)])
                if ["<=", ">=", "<>", "!=", "||", "->", "=>", "<<", ">>", "@>", "<@", "?|", "?&", "#>"].contains(two) {
                    toks.append(Tok(kind: .symbol, text: two)); i += 2; continue
                }
            }
            toks.append(Tok(kind: .symbol, text: String(c))); i += 1
        }
        return toks
    }

    // MARK: - 关键字与子句

    /// 保留关键字（大写匹配）；仅这些词参与大小写规范化。
    static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "ALTER", "DROP", "TABLE",
        "VIEW", "INDEX", "UNIQUE", "REPLACE", "TRUNCATE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL",
        "OUTER", "CROSS", "ON", "USING", "AS", "AND", "OR", "NOT", "NULL", "IS", "IN", "EXISTS",
        "BETWEEN", "LIKE", "ILIKE", "CASE", "WHEN", "THEN", "ELSE", "END", "DISTINCT", "ALL",
        "UNION", "INTERSECT", "EXCEPT", "WITH", "RECURSIVE", "ASC", "DESC", "NULLS", "FIRST",
        "LAST", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT", "DEFAULT", "CHECK",
        "CASCADE", "RESTRICT", "IF", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION", "RETURNING",
        "PARTITION", "WINDOW", "OVER", "ROWS", "RANGE", "PRECEDING", "FOLLOWING", "CURRENT",
        "ROW", "CAST", "COALESCE", "NULLIF", "TRUE", "FALSE", "COUNT", "SUM", "AVG", "MIN", "MAX",
        "INT", "INTEGER", "TEXT", "VARCHAR", "CHAR", "BOOLEAN", "BOOL", "DATE", "TIMESTAMP",
        "NUMERIC", "DECIMAL", "REAL", "DOUBLE", "PRECISION", "SERIAL", "BIGINT", "SMALLINT",
        "BLOB", "JSON", "JSONB", "UUID", "ARRAY", "COLLATE", "CONFLICT", "DO", "NOTHING",
        "EXPLAIN", "ANALYZE", "VERBOSE", "PRAGMA", "SHOW", "DESCRIBE", "USE", "DATABASE",
        "SCHEMA", "GRANT", "REVOKE", "TO", "PUBLIC", "ONLY", "LATERAL", "NATURAL", "SIMILAR",
        "ESCAPE", "ANY", "SOME", "DISTINCT", "GROUPING", "FILTER", "WITHIN", "ORDINALITY"
    ]

    /// 子句模式（按最长优先排序，便于贪心匹配）。
    static let clausePatterns: [[String]] = [
        ["CREATE", "OR", "REPLACE", "VIEW"],
        ["CREATE", "UNIQUE", "INDEX"],
        ["INSERT", "INTO"], ["DELETE", "FROM"],
        ["GROUP", "BY"], ["ORDER", "BY"], ["PARTITION", "BY"],
        ["UNION", "ALL"],
        ["LEFT", "OUTER", "JOIN"], ["RIGHT", "OUTER", "JOIN"], ["FULL", "OUTER", "JOIN"],
        ["INNER", "JOIN"], ["LEFT", "JOIN"], ["RIGHT", "JOIN"], ["FULL", "JOIN"], ["CROSS", "JOIN"],
        ["NATURAL", "JOIN"],
        ["CREATE", "TABLE"], ["CREATE", "VIEW"], ["CREATE", "INDEX"],
        ["ALTER", "TABLE"], ["DROP", "TABLE"], ["DROP", "VIEW"], ["TRUNCATE", "TABLE"],
        ["SELECT"], ["FROM"], ["WHERE"], ["HAVING"], ["LIMIT"], ["OFFSET"], ["FETCH"],
        ["UNION"], ["INTERSECT"], ["EXCEPT"], ["VALUES"], ["UPDATE"], ["SET"],
        ["WITH"], ["RETURNING"], ["JOIN"], ["ON"], ["USING"], ["TRUNCATE"],
        ["WINDOW"], ["INSERT"], ["DELETE"], ["CREATE"], ["ALTER"], ["DROP"]
    ]

    /// 列表逐项换行的子句。
    static let listClauses: Set<String> = ["SELECT", "GROUP BY", "ORDER BY"]

    // MARK: - Layout

    private final class Layout {
        let options: SQLFormatterOptions
        var out = ""
        var parenDepth = 0
        var parenIsSubquery: [Bool] = []
        var currentClause = ""
        var clauseParenDepth = 0
        var pendingListNewline = false
        var atLineStart = true
        var prevKind: TokKind?
        var prevText = ""
        var prevWasClause = false

        init(options: SQLFormatterOptions) { self.options = options }

        func indentString(_ level: Int) -> String {
            let unit = options.useTabs ? "\t" : String(repeating: " ", count: max(0, options.indentWidth))
            return String(repeating: unit, count: max(0, level))
        }

        func newline(_ level: Int) {
            out += "\n" + indentString(level)
            atLineStart = true
        }

        func transformWord(_ text: String) -> String {
            let up = text.uppercased()
            guard SQLFormatterService.keywords.contains(up) else { return text }
            switch options.keywordCase {
            case .upper: return up
            case .lower: return text.lowercased()
            case .preserve: return text
            }
        }

        /// 在 i 处贪心匹配子句；返回 (词数, 规范大写名, 展示文本)。
        func matchClause(_ toks: [Tok], _ i: Int) -> (Int, String, String)? {
            guard toks[i].kind == .word else { return nil }
            for pattern in SQLFormatterService.clausePatterns {
                let count = pattern.count
                guard i + count <= toks.count else { continue }
                var matched = true
                for k in 0..<count {
                    let t = toks[i + k]
                    if t.kind != .word || t.text.uppercased() != pattern[k] { matched = false; break }
                }
                if matched {
                    let canonical = pattern.joined(separator: " ")
                    let display = (0..<count).map { transformWord(toks[i + $0].text) }.joined(separator: " ")
                    return (count, canonical, display)
                }
            }
            return nil
        }

        /// 计算当前 token 前是否需要空格（不含强制换行场景）。
        func spaceBefore(_ kind: TokKind, _ text: String) -> Bool {
            if atLineStart || prevKind == nil { return false }
            if [",", ";", ")", ".", "::"].contains(text) { return false }
            if prevText == "(" || prevText == "." || prevText == "::" { return false }
            if text == "(" && (prevKind == .word || prevKind == .quotedIdent) && !prevWasClause { return false }
            if prevText == "-" && kind == .number { return false }
            return true
        }

        func emit(_ text: String, kind: TokKind) {
            if pendingListNewline {
                newline(parenDepth + 1)
                pendingListNewline = false
            } else if spaceBefore(kind, text) {
                out += " "
            }
            out += text
            atLineStart = false
            prevKind = kind
            prevText = text
            prevWasClause = false
        }

        func render(_ toks: [Tok]) -> String {
            var i = 0
            while i < toks.count {
                let tok = toks[i]

                // 子句换行
                if options.clausePerLine, let (count, canonical, display) = matchClause(toks, i) {
                    if !out.isEmpty && !atLineStart { newline(parenDepth) }
                    // 子句关键字本身按列表换行规则处理首项
                    emit(display, kind: .word)
                    prevWasClause = true
                    currentClause = canonical
                    clauseParenDepth = parenDepth
                    if SQLFormatterService.listClauses.contains(canonical) && options.commaNewlineInList {
                        pendingListNewline = true
                    }
                    i += count
                    continue
                }

                switch tok.text {
                case "," where tok.kind == .symbol:
                    emit(",", kind: .symbol)
                    if options.commaNewlineInList
                        && SQLFormatterService.listClauses.contains(currentClause)
                        && parenDepth == clauseParenDepth {
                        newline(parenDepth + 1)
                    }
                    i += 1
                    continue
                case ";" where tok.kind == .symbol:
                    emit(";", kind: .symbol)
                    parenDepth = 0
                    parenIsSubquery = []
                    currentClause = ""
                    clauseParenDepth = 0
                    pendingListNewline = false
                    if i + 1 < toks.count { newline(0) }
                    i += 1
                    continue
                case "(" where tok.kind == .symbol:
                    emit("(", kind: .symbol)
                    parenDepth += 1
                    let nextIsQuery = (i + 1 < toks.count)
                        && toks[i + 1].kind == .word
                        && ["SELECT", "WITH"].contains(toks[i + 1].text.uppercased())
                    parenIsSubquery.append(nextIsQuery)
                    if nextIsQuery { newline(parenDepth) }
                    i += 1
                    continue
                case ")" where tok.kind == .symbol:
                    let wasSub = parenIsSubquery.popLast() ?? false
                    parenDepth = max(0, parenDepth - 1)
                    if wasSub && !atLineStart { newline(parenDepth) }
                    emit(")", kind: .symbol)
                    i += 1
                    continue
                default:
                    break
                }

                switch tok.kind {
                case .lineComment:
                    if !atLineStart && prevKind != nil { out += " " }
                    out += tok.text
                    newline(parenDepth)
                    prevKind = .lineComment
                    prevText = tok.text
                    i += 1
                    continue
                case .word:
                    emit(transformWord(tok.text), kind: .word)
                case .blockComment:
                    emit(tok.text, kind: .blockComment)
                default:
                    emit(tok.text, kind: tok.kind)
                }
                i += 1
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}