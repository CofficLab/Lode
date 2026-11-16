import Foundation

/// SQL 语句切分器：按 `;` 把一段 SQL 切成独立的可执行语句。
///
/// 尊重：
/// - 单引号字符串字面量（含 `''` 转义）
/// - 双引号标识符（含 `""` 转义）
/// - 反引号标识符（MySQL，含 ` `` ` 转义）
/// - 行注释（`--` 到行尾）
/// - 块注释（`/* ... */`，可嵌套）
///
/// 空语句（仅空白/注释）被过滤。返回的语句保留原始空白以便错误定位。
public enum SQLStatementParser {
    /// 返回 `index` 之后的字符位置；没有下一个字符时返回 `nil`。
    ///
    /// `String.index(_:offsetBy:limitedBy:)` 在恰好走到末尾时会返回
    /// `endIndex`，而调用方随后会直接下标访问，造成越界 trap。这里统一
    /// 把 `endIndex` 归一成 `nil`，让所有 `next` 都保证可安全下标。
    private static func nextIndex(in string: String, after index: String.Index) -> String.Index? {
        guard let next = string.index(index, offsetBy: 1, limitedBy: string.endIndex),
              next < string.endIndex else {
            return nil
        }
        return next
    }

    /// 一条语句在源文本中的定位结果。
    public struct LocatedStatement: Sendable, Equatable {
        /// 已 trim 的语句文本。
        public let text: String
        /// 原始片段（含前后空白，不含分隔分号）在源文本中的 UTF-16 范围。
        public let range: NSRange
        /// 去除注释/空白后是否仍有可执行内容；纯注释/空白片段为 false。
        public let isExecutable: Bool

        public init(text: String, range: NSRange, isExecutable: Bool) {
            self.text = text
            self.range = range
            self.isExecutable = isExecutable
        }
    }

    public static func split(_ sql: String) -> [String] {
        locateStatements(in: sql).filter(\.isExecutable).map(\.text)
    }

    /// 返回光标（UTF-16 偏移）所在的可执行语句文本；光标落在空白/注释间隙或越界时返回 nil。
    ///
    /// 复用 ``locateStatements(in:)`` 的切分边界，因此引号内分号、注释、嵌套块注释
    /// 都不会被误判为语句分隔。范围上界取闭区间，使「光标停在末句尾部」也能命中。
    public static func statement(atCursor cursor: Int, in sql: String) -> String? {
        guard cursor >= 0 else { return nil }
        for located in locateStatements(in: sql) where located.isExecutable {
            let upper = located.range.location + located.range.length
            if cursor >= located.range.location && cursor <= upper {
                return located.text
            }
        }
        return nil
    }

    /// 按 `;` 切分并保留每条语句的原始 UTF-16 范围，供光标定位与错误高亮复用。
    ///
    /// 状态机与 ``split(_:)`` 完全一致（后者即本函数的可执行片段投影），
    /// 尊重单/双/反引号（含双写转义）、行注释与可嵌套块注释。
    public static func locateStatements(in sql: String) -> [LocatedStatement] {
        var result: [LocatedStatement] = []
        var current = ""
        var index = sql.startIndex
        var segmentStart = sql.startIndex
        var inString: Character? = nil
        var inLineComment = false
        var blockCommentDepth = 0

        func utf16Offset(_ i: String.Index) -> Int {
            sql.utf16.distance(from: sql.startIndex, to: i)
        }

        /// 去除注释后是否仍有实际内容（避免纯注释语句占位）。
        func hasExecutableContent(_ statement: String) -> Bool {
            var stripped = ""
            var i = statement.startIndex
            var inStr: Character? = nil
            var inLC = false
            var bcDepth = 0
            while i < statement.endIndex {
                let c = statement[i]
                let n = Self.nextIndex(in: statement, after: i)
                if inLC {
                    if c == "\n" { inLC = false }
                    i = statement.index(after: i); continue
                }
                if bcDepth > 0 {
                    if c == "/" && n != nil && statement[n!] == "*" { bcDepth += 1; i = statement.index(after: n!); continue }
                    if c == "*" && n != nil && statement[n!] == "/" { bcDepth -= 1; i = statement.index(after: n!); continue }
                    i = statement.index(after: i); continue
                }
                if let q = inStr {
                    if c == q {
                        if let nn = n, nn < statement.endIndex, statement[nn] == q { i = statement.index(after: nn); continue }
                        inStr = nil
                    }
                    i = statement.index(after: i); continue
                }
                if c == "'" || c == "\"" || c == "`" { inStr = c; i = statement.index(after: i); continue }
                if c == "-" && n != nil && statement[n!] == "-" { inLC = true; i = statement.index(after: i); continue }
                if c == "/" && n != nil && statement[n!] == "*" { bcDepth = 1; i = statement.index(after: n!); continue }
                stripped.append(c)
                i = statement.index(after: i)
            }
            return !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        func commitCurrentStatement(upTo end: String.Index) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let location = utf16Offset(segmentStart)
                let length = max(0, utf16Offset(end) - location)
                result.append(LocatedStatement(
                    text: trimmed,
                    range: NSRange(location: location, length: length),
                    isExecutable: hasExecutableContent(trimmed)
                ))
            }
            current = ""
            if end < sql.endIndex {
                segmentStart = sql.index(after: end)
            }
        }

        while index < sql.endIndex {
            let ch = sql[index]
            let next = Self.nextIndex(in: sql, after: index)

            // 行注释状态
            if inLineComment {
                current.append(ch)
                if ch == "\n" { inLineComment = false }
                index = sql.index(after: index)
                continue
            }

            // 块注释状态（可嵌套）
            if blockCommentDepth > 0 {
                current.append(ch)
                if ch == "/" && next != nil && sql[next!] == "*" {
                    blockCommentDepth += 1
                    current.append(sql[next!])
                    index = sql.index(after: next!)
                    continue
                }
                if ch == "*" && next != nil && sql[next!] == "/" {
                    blockCommentDepth -= 1
                    current.append(sql[next!])
                    index = sql.index(after: next!)
                    continue
                }
                index = sql.index(after: index)
                continue
            }

            // 字符串字面量状态
            if let quote = inString {
                current.append(ch)
                if ch == quote {
                    // 转义：两个连续引号
                    if let n = next, n < sql.endIndex, sql[n] == quote {
                        current.append(sql[n])
                        index = sql.index(after: n)
                        continue
                    }
                    inString = nil
                }
                index = sql.index(after: index)
                continue
            }

            // 进入字符串
            if ch == "'" || ch == "\"" || ch == "`" {
                inString = ch
                current.append(ch)
                index = sql.index(after: index)
                continue
            }

            // 进入行注释
            if ch == "-" && next != nil && sql[next!] == "-" {
                inLineComment = true
                current.append(ch)
                index = sql.index(after: index)
                continue
            }

            // 进入块注释
            if ch == "/" && next != nil && sql[next!] == "*" {
                blockCommentDepth = 1
                current.append(ch)
                current.append(sql[next!])
                index = sql.index(after: next!)
                continue
            }

            // 语句分隔符
            if ch == ";" {
                commitCurrentStatement(upTo: index)
                index = sql.index(after: index)
                continue
            }

            current.append(ch)
            index = sql.index(after: index)
        }

        // 收尾：最后一段（可能没有尾部分号）
        commitCurrentStatement(upTo: sql.endIndex)
        return result
    }

    /// 剥离字符串字面量、注释与带引号标识符，只保留「代码骨架」。
    ///
    /// 用于只读策略判定：安全检查关心的是**代码里出现了什么**，
    /// 而不是文本内容里出现了什么。
    /// `SELECT 'DROP' AS word` 的骨架是 `SELECT  AS word` —— 里面没有写操作；
    /// `SELECT * FROM t WHERE x = DROP()` 的骨架里 `DROP` 仍是裸关键字，仍会被拦下。
    ///
    /// 尊重的语法与 ``split(_:)`` 一致：
    /// - 单引号字符串字面量（含 `''` 转义）
    /// - 双引号标识符（含 `""` 转义）
    /// - 反引号标识符（MySQL，含 `` `` `` 转义）
    /// - 行注释（`--` 到行尾）与块注释（`/* ... */`，可嵌套）
    public static func stripLiteralsAndComments(_ sql: String) -> String {
        var result = ""
        var index = sql.startIndex
        var inString: Character? = nil
        var inLineComment = false
        var blockCommentDepth = 0

        while index < sql.endIndex {
            let ch = sql[index]
            let next = Self.nextIndex(in: sql, after: index)

            if inLineComment {
                if ch == "\n" {
                    inLineComment = false
                    result.append(ch)
                }
                index = sql.index(after: index)
                continue
            }

            if blockCommentDepth > 0 {
                if ch == "/" && next != nil && sql[next!] == "*" {
                    blockCommentDepth += 1
                    index = sql.index(after: next!)
                    continue
                }
                if ch == "*" && next != nil && sql[next!] == "/" {
                    blockCommentDepth -= 1
                    index = sql.index(after: next!)
                    continue
                }
                index = sql.index(after: index)
                continue
            }

            if let quote = inString {
                if ch == quote {
                    // 转义：两个连续引号
                    if let n = next, n < sql.endIndex, sql[n] == quote {
                        index = sql.index(after: n)
                        continue
                    }
                    inString = nil
                }
                index = sql.index(after: index)
                continue
            }

            // 进入字符串 / 标识符：整段丢弃，只留一个空格占位。
            if ch == "\'" || ch == "\"" || ch == "`" {
                inString = ch
                result.append(" ")
                index = sql.index(after: index)
                continue
            }

            // 进入行注释
            if ch == "-" && next != nil && sql[next!] == "-" {
                inLineComment = true
                index = sql.index(after: index)
                continue
            }

            // 进入块注释
            if ch == "/" && next != nil && sql[next!] == "*" {
                blockCommentDepth = 1
                index = sql.index(after: next!)
                continue
            }

            result.append(ch)
            index = sql.index(after: index)
        }

        return result
    }
}
