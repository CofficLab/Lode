import Foundation

/// SQL 折叠区间计算器：从文本中找出可折叠的多行块。
///
/// 覆盖四类块（均尊重字符串字面量、行注释与可嵌套块注释）：
/// - 语句：每条跨多行的独立语句（复用 ``SQLStatementParser/locateStatements(in:)`` 的边界）；
/// - 圆括号块：`(...)` 跨多行（涵盖 CTE 的 `AS (...)` 体与子查询）；
/// - BEGIN…END 块：跨多行的关键字配对（大小写不敏感，按词边界识别）；
/// - 块注释：`/* ... */` 跨多行。
///
/// 只返回真正跨多行的块（单行块无可折叠内容）。范围用 UTF-16 `NSRange` 表示，
/// 与编辑器文本存储一致；嵌套块各自独立返回，由折叠模型按深度组织。
public enum SQLFoldRangeCalculator {
    /// 折叠块种类。
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case statement, parenthesis, beginEnd, blockComment
    }

    /// 一个可折叠块在源文本中的定位。
    public struct FoldRange: Sendable, Equatable {
        /// 块种类。
        public let kind: Kind
        /// 块的 UTF-16 范围（含起止边界字符，如圆括号本身）。
        public let range: NSRange

        public init(kind: Kind, range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    /// 计算文本中所有跨多行的可折叠块，按起点升序返回。
    public static func foldRanges(in sql: String) -> [FoldRange] {
        guard !sql.isEmpty else { return [] }
        var ranges: [FoldRange] = []

        // 语句块：复用切分器的引号/注释感知边界。
        for located in SQLStatementParser.locateStatements(in: sql) where located.isExecutable {
            if spansMultipleLines(located.range, in: sql) {
                ranges.append(FoldRange(kind: .statement, range: located.range))
            }
        }

        // 单遍扫描圆括号 / BEGIN…END / 块注释。
        ranges.append(contentsOf: scanBlocks(in: sql))

        return ranges.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }
    }

    // MARK: - Scanning

    private static func scanBlocks(in sql: String) -> [FoldRange] {
        var result: [FoldRange] = []
        var parenStack: [String.Index] = []
        var beginStack: [String.Index] = []
        var commentStack: [String.Index] = []
        var inString: Character? = nil
        var inLineComment = false
        var word = ""

        var index = sql.startIndex
        while index < sql.endIndex {
            let ch = sql[index]
            let next = sql.index(index, offsetBy: 1, limitedBy: sql.endIndex)
            let nextChar: Character? = (next != nil && next! < sql.endIndex) ? sql[next!] : nil

            if inLineComment {
                if ch == "\n" { inLineComment = false }
                index = sql.index(after: index)
                continue
            }

            if !commentStack.isEmpty {
                if ch == "/" && nextChar == "*" {
                    commentStack.append(index)
                    index = sql.index(after: next!)
                    continue
                }
                if ch == "*" && nextChar == "/" {
                    let start = commentStack.removeLast()
                    let end = sql.index(after: next!)
                    appendBlock(.blockComment, from: start, to: end, in: sql, into: &result)
                    index = end
                    continue
                }
                index = sql.index(after: index)
                continue
            }

            if let quote = inString {
                if ch == quote {
                    if let n = nextChar, n == quote {
                        index = sql.index(after: next!)
                        continue
                    }
                    inString = nil
                }
                index = sql.index(after: index)
                continue
            }

            // 词边界关键字识别（仅在代码骨架中累积标识符字符，避免 END2 之类被误判）。
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" {
                word.append(ch)
                index = sql.index(after: index)
                continue
            }
            if !word.isEmpty {
                let upper = word.uppercased()
                if upper == "BEGIN" {
                    beginStack.append(sql.index(index, offsetBy: -word.count))
                } else if upper == "END", let start = beginStack.popLast() {
                    appendBlock(.beginEnd, from: start, to: index, in: sql, into: &result)
                }
                word = ""
            }

            if ch == "'" || ch == "\"" || ch == "`" {
                inString = ch
                index = sql.index(after: index)
                continue
            }
            if ch == "-" && nextChar == "-" {
                inLineComment = true
                index = sql.index(after: index)
                continue
            }
            if ch == "/" && nextChar == "*" {
                commentStack.append(index)
                index = sql.index(after: next!)
                continue
            }
            if ch == "(" {
                parenStack.append(index)
                index = sql.index(after: index)
                continue
            }
            if ch == ")", let start = parenStack.popLast() {
                let end = sql.index(after: index)
                appendBlock(.parenthesis, from: start, to: end, in: sql, into: &result)
                index = end
                continue
            }

            index = sql.index(after: index)
        }

        // 收尾：文本末尾的标识符（如恰好以 END 结尾）也要参与关键字配对。
        if !word.isEmpty {
            let upper = word.uppercased()
            if upper == "BEGIN" {
                beginStack.append(sql.index(index, offsetBy: -word.count))
            } else if upper == "END", let start = beginStack.popLast() {
                appendBlock(.beginEnd, from: start, to: sql.endIndex, in: sql, into: &result)
            }
        }

        return result
    }

    /// 记录一个块：仅当跨多行时纳入。`to` 为块结束后的开区间上界。
    private static func appendBlock(
        _ kind: Kind,
        from start: String.Index,
        to end: String.Index,
        in sql: String,
        into result: inout [FoldRange]
    ) {
        let location = sql.utf16.distance(from: sql.startIndex, to: start)
        let upper = sql.utf16.distance(from: sql.startIndex, to: end)
        let range = NSRange(location: location, length: max(0, upper - location))
        if spansMultipleLines(range, in: sql) {
            result.append(FoldRange(kind: kind, range: range))
        }
    }

    /// 范围内部（不含首字符所在行的行首）是否含有换行，即是否跨多行。
    private static func spansMultipleLines(_ range: NSRange, in sql: String) -> Bool {
        guard range.length > 0 else { return false }
        let ns = sql as NSString
        let inner = NSRange(location: range.location, length: range.length)
        return ns.range(of: "\n", options: [], range: inner).location != NSNotFound
    }
}