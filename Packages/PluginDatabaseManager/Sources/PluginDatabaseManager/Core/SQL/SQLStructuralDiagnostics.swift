import Foundation

/// 一条结构化 SQL 诊断：编辑器内标记 + 诊断条展示共用。
///
/// 范围以 UTF-16 码元计（与 `NSTextView`/`NSRange` 一致），可直接用于编辑器强调层。
public struct SQLStructuralDiagnostic: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case error
        case warning
    }

    public enum Kind: Equatable, Sendable {
        /// 开括号没有对应的闭括号。
        case unmatchedOpeningBracket
        /// 闭括号没有开括号，或与栈顶开括号类型不匹配。
        case unexpectedClosingBracket
        /// 字符串/引用标识符/美元引用字面量未闭合。
        case unterminatedString
        /// 块注释未闭合。
        case unterminatedComment
        /// 形近字符（如西里尔 а 形似拉丁 a），关联值为其形似的 ASCII 字符。
        case confusableCharacter(ascii: String)
        /// 不可见字符（零宽连接符、不间断空格等）。
        case invisibleCharacter
    }

    public let range: NSRange
    public let kind: Kind

    public var severity: Severity {
        switch kind {
        case .confusableCharacter, .invisibleCharacter:
            return .warning
        case .unmatchedOpeningBracket, .unexpectedClosingBracket, .unterminatedString, .unterminatedComment:
            return .error
        }
    }

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// 结构化 SQL 诊断扫描器：括号配对、引号/注释闭合、形近与不可见字符。
///
/// 纯函数、无副作用，可在每次文本变化时同步调用。词法状态机与
/// ``SQLStatementParser`` 保持一致的口径：
/// - 单引号字符串（`''`  doubling 转义 + 反斜杠转义，MySQL 风格启发式）
/// - 双引号/反引号标识符（doubling 转义）
/// - 美元引用字面量 `$$...$$` / `$tag$...$tag$`（PostgreSQL）
/// - 行注释 `--` 与 `#`（MySQL）
/// - 块注释 `/* ... */`，按 PostgreSQL 语义支持嵌套
///
/// 形近/不可见字符只在字面量与注释之外报告（字符串数据里的 NBSP 是合法内容）。
/// 形近表是精选启发式子集（常见西里尔/希腊形似字符），不追求穷尽。
/// 输出按位置排序并截断到 ``maximumCount``，避免大文档产生过多标记层。
public enum SQLStructuralDiagnostics {
    /// 单次扫描最多返回的诊断条数。
    public static let maximumCount = 100

    /// 西里尔/希腊形似字符 → 其形似的 ASCII 字符。
    private static let confusables: [UnicodeScalar: String] = [
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x",
        "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "ԛ": "q", "ԝ": "w",
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
        "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I", "Ј": "J",
        "Ѕ": "S", "Ү": "Y",
        "ο": "o", "Ο": "O",
    ]

    /// 零宽/不可见字符集合。
    private static let invisibles: Set<UnicodeScalar> = [
        "\u{00A0}", "\u{00AD}", "\u{180E}",
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
    ]

    private enum State: Equatable {
        case code
        case singleQuote
        case doubleQuote
        case backtick
        case lineComment
        case blockComment(depth: Int)
    }

    public static func scan(_ text: String) -> [SQLStructuralDiagnostic] {
        let scalars = Array(text.unicodeScalars)
        let endOffset = text.utf16.count
        var results: [SQLStructuralDiagnostic] = []
        var brackets: [(scalar: UnicodeScalar, offset: Int)] = []
        var state: State = .code
        var literalStart = 0
        var i = 0
        var offset = 0

        func emit(_ kind: SQLStructuralDiagnostic.Kind, at location: Int, length: Int) {
            guard results.count < maximumCount else { return }
            results.append(SQLStructuralDiagnostic(range: NSRange(location: location, length: length), kind: kind))
        }

        func isBracketOpener(_ s: UnicodeScalar) -> Bool { s == "(" || s == "[" || s == "{" }
        func closer(for s: UnicodeScalar) -> UnicodeScalar? {
            switch s {
            case "(": return ")"
            case "[": return "]"
            case "{": return "}"
            default: return nil
            }
        }
        func isBracketCloser(_ s: UnicodeScalar) -> Bool { s == ")" || s == "]" || s == "}" }

        while i < scalars.count {
            let s = scalars[i]
            let width = s.utf16.count
            let next: UnicodeScalar? = i + 1 < scalars.count ? scalars[i + 1] : nil

            switch state {
            case .code:
                if s == "'" {
                    state = .singleQuote
                    literalStart = offset
                } else if s == "\"" {
                    state = .doubleQuote
                    literalStart = offset
                } else if s == "`" {
                    state = .backtick
                    literalStart = offset
                } else if s == "-" && next == "-" {
                    state = .lineComment
                    i += 1
                    offset += 1
                } else if s == "#" {
                    state = .lineComment
                } else if s == "/" && next == "*" {
                    state = .blockComment(depth: 1)
                    literalStart = offset
                    i += 1
                    offset += 1
                } else if s == "$", let literalEnd = dollarLiteralEnd(scalars, from: i) {
                    // 美元引用字面量：整体跳过（含未闭合情形）。
                    if literalEnd < 0 {
                        emit(.unterminatedString, at: offset, length: endOffset - offset)
                        offset = endOffset
                        i = scalars.count
                        continue
                    }
                    offset += literalEnd
                    i += scalarCount(scalars, from: i, utf16Length: literalEnd)
                    continue
                } else if isBracketOpener(s) {
                    brackets.append((s, offset))
                } else if isBracketCloser(s) {
                    if let top = brackets.last, closer(for: top.scalar) == s {
                        brackets.removeLast()
                    } else {
                        if !brackets.isEmpty { brackets.removeLast() }
                        emit(.unexpectedClosingBracket, at: offset, length: width)
                    }
                } else if let ascii = confusables[s] {
                    emit(.confusableCharacter(ascii: ascii), at: offset, length: width)
                } else if invisibles.contains(s) {
                    emit(.invisibleCharacter, at: offset, length: width)
                }

            case .singleQuote:
                if s == "\\" && next != nil {
                    i += 1
                    offset += next!.utf16.count
                } else if s == "'" {
                    if next == "'" {
                        i += 1
                        offset += 1
                    } else {
                        state = .code
                    }
                }

            case .doubleQuote, .backtick:
                let quote: UnicodeScalar = state == .doubleQuote ? "\"" : "`"
                if s == quote {
                    if next == quote {
                        i += 1
                        offset += 1
                    } else {
                        state = .code
                    }
                }

            case .lineComment:
                if s == "\n" || s == "\r" {
                    state = .code
                }

            case .blockComment(let depth):
                if s == "/" && next == "*" {
                    state = .blockComment(depth: depth + 1)
                    i += 1
                    offset += 1
                } else if s == "*" && next == "/" {
                    if depth <= 1 {
                        state = .code
                    } else {
                        state = .blockComment(depth: depth - 1)
                    }
                    i += 1
                    offset += 1
                }
            }

            i += 1
            offset += width
        }

        switch state {
        case .singleQuote, .doubleQuote, .backtick:
            emit(.unterminatedString, at: literalStart, length: endOffset - literalStart)
        case .blockComment:
            emit(.unterminatedComment, at: literalStart, length: endOffset - literalStart)
        case .code, .lineComment:
            break
        }

        for bracket in brackets {
            emit(.unmatchedOpeningBracket, at: bracket.offset, length: bracket.scalar.utf16.count)
        }

        return results.sorted { $0.range.location < $1.range.location }
    }

    /// 若 `scalars[start]` 起是美元引用开定界符 `$tag$`，返回整个字面量的 UTF-16 长度；
    /// 未闭合返回 -1；不是美元引用返回 nil。
    private static func dollarLiteralEnd(_ scalars: [UnicodeScalar], from start: Int) -> Int? {
        var j = start + 1
        while j < scalars.count, isDollarTagScalar(scalars[j]) { j += 1 }
        guard j < scalars.count, scalars[j] == "$" else { return nil }
        let tagLength = j - start + 1
        var k = j + 1
        while k < scalars.count {
            if scalars[k] == "$", k + tagLength <= scalars.count,
               Array(scalars[k..<(k + tagLength)]) == Array(scalars[start..<(start + tagLength)]) {
                var utf16 = 0
                for scalar in scalars[start..<(k + tagLength)] { utf16 += scalar.utf16.count }
                return utf16
            }
            k += 1
        }
        return -1
    }

    private static func isDollarTagScalar(_ s: UnicodeScalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "_"
    }

    /// 从 `start` 起消耗 `utf16Length` 个 UTF-16 码元对应的标量个数。
    private static func scalarCount(_ scalars: [UnicodeScalar], from start: Int, utf16Length: Int) -> Int {
        var remaining = utf16Length
        var count = 0
        var idx = start
        while remaining > 0, idx < scalars.count {
            remaining -= scalars[idx].utf16.count
            idx += 1
            count += 1
        }
        return count
    }
}