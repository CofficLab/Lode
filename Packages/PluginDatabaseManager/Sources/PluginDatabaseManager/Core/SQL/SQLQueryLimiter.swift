import Foundation

/// ``SQLQueryLimiter/apply(_:limit:)`` 的结果。
public struct SQLQueryLimitResult: Equatable, Sendable {
    /// 实际交给驱动执行的 SQL。
    public let sql: String
    /// 注入的行数上限；nil 表示用户自带 LIMIT/FETCH 或语句不适用注入。
    public let injectedLimit: Int?
    /// 注入时的基础语句（去掉尾部分号），供「加载更多」拼接 OFFSET 窗口。
    public let baseSQL: String?

    public init(sql: String, injectedLimit: Int?, baseSQL: String?) {
        self.sql = sql
        self.injectedLimit = injectedLimit
        self.baseSQL = baseSQL
    }
}

/// 为没有行数上限的 SELECT 注入 LIMIT，防止全表结果一次性进内存。
///
/// 规则：
/// - 只处理单条 SELECT / WITH 语句；多语句、写语句、PRAGMA 等原样返回；
/// - 顶层已有 LIMIT 或 FETCH（PG 标准写法）时尊重用户值，不注入；
/// - 子查询里的 LIMIT 不算数（按括号深度判定）；
/// - 注入点避开 OFFSET / FOR UPDATE / LOCK 等必须位于 LIMIT 之后的子句。
public enum SQLQueryLimiter {
    public static func apply(_ sql: String, limit: Int) -> SQLQueryLimitResult {
        let unchanged = SQLQueryLimitResult(sql: sql, injectedLimit: nil, baseSQL: nil)
        guard limit > 0 else { return unchanged }
        guard SQLStatementParser.split(sql).count == 1 else { return unchanged }

        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return unchanged }

        let scan = scanTopLevel(trimmed)
        guard let first = scan.words.first, first.text == "SELECT" || first.text == "WITH" else {
            return unchanged
        }
        // WITH 开头也可能是数据修改 CTE（PG 的 WITH ... INSERT），不能注入。
        // 但 FOR UPDATE / FOR NO KEY UPDATE 是锁子句，不是写语句。
        var sawFor = false
        for word in scan.words {
            if word.text == "FOR" { sawFor = true }
            if ["INSERT", "UPDATE", "DELETE", "MERGE"].contains(word.text) {
                if word.text == "UPDATE" && sawFor { continue }
                return unchanged
            }
        }
        if scan.words.contains(where: { $0.text == "LIMIT" || $0.text == "FETCH" }) {
            return SQLQueryLimitResult(sql: trimmed, injectedLimit: nil, baseSQL: nil)
        }

        // LIMIT 必须出现在 OFFSET / FOR UPDATE / LOCK IN SHARE MODE 之前。
        let insertionIndex = scan.words.first(where: {
            $0.text == "OFFSET" || $0.text == "FOR" || $0.text == "LOCK"
        })?.start ?? trimmed.endIndex

        let limited: String
        if insertionIndex == trimmed.endIndex {
            // 追加到末尾时换行开头，避免落在行注释里。
            limited = trimmed + "\nLIMIT \(limit)"
        } else {
            var copy = trimmed
            copy.insert(contentsOf: "LIMIT \(limit) ", at: insertionIndex)
            limited = copy
        }
        return SQLQueryLimitResult(sql: limited, injectedLimit: limit, baseSQL: trimmed)
    }

    private struct Word {
        let text: String
        let start: String.Index
    }

    private struct ScanResult {
        let words: [Word]
    }

    /// 跳过字符串/注释，收集括号深度 0 的单词及其在原文中的起始位置。
    private static func scanTopLevel(_ sql: String) -> ScanResult {
        var words: [Word] = []
        var depth = 0
        var quote: Character?
        var inLineComment = false
        var blockCommentDepth = 0
        var current = ""
        var currentStart: String.Index?

        func flush() {
            if !current.isEmpty, let start = currentStart {
                words.append(Word(text: current.uppercased(), start: start))
            }
            current = ""
            currentStart = nil
        }

        var index = sql.startIndex
        while index < sql.endIndex {
            let ch = sql[index]
            let next = sql.index(after: index)

            if inLineComment {
                if ch == "\n" { inLineComment = false }
                index = next
                continue
            }
            if blockCommentDepth > 0 {
                if ch == "/", next < sql.endIndex, sql[next] == "*" {
                    blockCommentDepth += 1
                    index = sql.index(after: next)
                    continue
                }
                if ch == "*", next < sql.endIndex, sql[next] == "/" {
                    blockCommentDepth -= 1
                    index = sql.index(after: next)
                    continue
                }
                index = next
                continue
            }
            if let q = quote {
                if ch == q {
                    if next < sql.endIndex, sql[next] == q {
                        index = sql.index(after: next)
                        continue
                    }
                    quote = nil
                }
                index = next
                continue
            }

            if ch == "'" || ch == "\"" || ch == "`" {
                flush()
                quote = ch
                index = next
                continue
            }
            if ch == "-", next < sql.endIndex, sql[next] == "-" {
                flush()
                inLineComment = true
                index = sql.index(after: next)
                continue
            }
            if ch == "/", next < sql.endIndex, sql[next] == "*" {
                flush()
                blockCommentDepth = 1
                index = sql.index(after: next)
                continue
            }
            if ch == "(" {
                flush()
                depth += 1
                index = next
                continue
            }
            if ch == ")" {
                flush()
                depth = max(0, depth - 1)
                index = next
                continue
            }

            if depth == 0, ch.isLetter || ch == "_" {
                if currentStart == nil { currentStart = index }
                current.append(ch)
            } else {
                flush()
            }
            index = next
        }
        flush()
        return ScanResult(words: words)
    }
}