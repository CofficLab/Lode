import Foundation

/// 命名查询参数（`:name`）的提取与位置化改写。
///
/// 与 ``SQLStatementParser`` 尊重同一套语法：单/双/反引号（含双写转义）、
/// 行注释与可嵌套块注释；`::` 类型转换不算参数。提取按出现顺序返回，
/// 改写把每个 `:name` 替换为引擎占位符并按出现顺序生成绑定值数组，
/// 从而复用各驱动既有的位置参数预处理通道（MySQL/SQLite `?`、PostgreSQL `$n`）。
public enum SQLNamedParameters {
    /// 一次 `:name` 出现。
    public struct Occurrence: Sendable, Equatable {
        /// 参数名（不含前导冒号）。
        public let name: String
        /// `:name` 整体在源文本中的 UTF-16 范围。
        public let range: NSRange

        public init(name: String, range: NSRange) {
            self.name = name
            self.range = range
        }
    }

    /// 按出现顺序返回所有 `:name`（重复名字多次出现）。
    public static func occurrences(in sql: String) -> [Occurrence] {
        let chars = Array(sql)
        let n = chars.count
        guard n > 0 else { return [] }
        // 预计算每个 Character 起点的 UTF-16 偏移，避免逐次 distance 的 O(n²)。
        var utf16Start = [Int](repeating: 0, count: n + 1)
        for i in 0..<n { utf16Start[i + 1] = utf16Start[i] + String(chars[i]).utf16.count }

        func isWordStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isWordPart(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

        var result: [Occurrence] = []
        var i = 0
        var inString: Character?
        var inLineComment = false
        var blockDepth = 0

        while i < n {
            let c = chars[i]
            if inLineComment {
                if c == "\n" { inLineComment = false }
                i += 1; continue
            }
            if blockDepth > 0 {
                if c == "/" && i + 1 < n && chars[i + 1] == "*" { blockDepth += 1; i += 2; continue }
                if c == "*" && i + 1 < n && chars[i + 1] == "/" { blockDepth -= 1; i += 2; continue }
                i += 1; continue
            }
            if let q = inString {
                if c == q {
                    if i + 1 < n && chars[i + 1] == q { i += 2; continue }
                    inString = nil
                }
                i += 1; continue
            }
            if c == "'" || c == "\"" || c == "`" { inString = c; i += 1; continue }
            if c == "-" && i + 1 < n && chars[i + 1] == "-" { inLineComment = true; i += 2; continue }
            if c == "/" && i + 1 < n && chars[i + 1] == "*" { blockDepth = 1; i += 2; continue }
            if c == ":" {
                // `::` 是类型转换，不是参数。
                if i + 1 < n && chars[i + 1] == ":" { i += 2; continue }
                if i + 1 < n && isWordStart(chars[i + 1]) {
                    var j = i + 1
                    while j < n && isWordPart(chars[j]) { j += 1 }
                    let name = String(chars[(i + 1)..<j])
                    let range = NSRange(location: utf16Start[i], length: utf16Start[j] - utf16Start[i])
                    result.append(Occurrence(name: name, range: range))
                    i = j; continue
                }
                i += 1; continue
            }
            i += 1
        }
        return result
    }

    /// 去重后的参数名，按首次出现顺序排列。
    public static func names(in sql: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for occ in occurrences(in: sql) where !seen.contains(occ.name) {
            seen.insert(occ.name)
            ordered.append(occ.name)
        }
        return ordered
    }

    /// 把每个 `:name` 改写为引擎占位符，并按出现顺序生成绑定值。
    ///
    /// - Parameters:
    ///   - placeholder: 第 index 次出现（0 起）对应的占位符文本（`?` 或 `$n`）。
    ///   - value: 参数名到绑定值的映射；同名多次出现复用同一值。
    /// - Returns: 改写后的 SQL 与出现顺序的绑定值数组；无参数时原样返回、数组为空。
    public static func rewrite(
        _ sql: String,
        placeholder: (Int) -> String,
        value: (String) -> DatabaseValue
    ) -> (sql: String, params: [DatabaseValue]) {
        let occ = occurrences(in: sql)
        guard !occ.isEmpty else { return (sql, []) }
        var mutable = sql as NSString
        // 从后往前替换，保证靠前出现的 UTF-16 范围不被后续替换偏移。
        for (index, occurrence) in occ.enumerated().reversed() {
            mutable = mutable.replacingCharacters(in: occurrence.range, with: placeholder(index)) as NSString
        }
        let params = occ.map { value($0.name) }
        return (mutable as String, params)
    }
}