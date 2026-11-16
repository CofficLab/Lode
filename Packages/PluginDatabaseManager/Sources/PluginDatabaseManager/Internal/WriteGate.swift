import Foundation

/// 写权限闸门的判定结果（纯函数，便于「三档 × 写路径」矩阵测试）。
public enum WriteGateDecision: Equatable, Sendable {
    /// 放行：读语句，或安全模式为 off。
    case proceed
    /// 需要用户确认后才执行（confirmWrites 档的写操作）。
    case requiresConfirmation
    /// 拒绝执行（readOnly 档的写操作）。
    case blocked
}

/// VM 层写闸门的最终授权结果。
public enum WriteAuthorization: Equatable, Sendable {
    /// 可继续执行。
    case authorized
    /// 被安全模式拒绝（readOnly）。
    case blocked
    /// 用户在确认弹窗中取消。
    case cancelled
}

/// 触发写闸门的操作类型，用于确认弹窗的标题/文案。
public enum WriteOperationKind: Sendable {
    /// 编辑器单句执行。
    case query
    /// 编辑器批量执行。
    case batch
    /// 表数据变更队列提交。
    case tableEdit
    /// 结构变更（DDL）提交。
    case schemaChange
}

/// 写语句识别与写权限闸门。
///
/// 与 ``DatabaseViewModel/isReadStatement(_:type:)`` 的区别：后者决定「走 query 还是
/// execute」以正确展示结果行（`INSERT ... RETURNING` 被当作读以便取回返回行）；
/// 本类型决定「是否修改数据/结构」，用于安全闸门——`RETURNING` 写、`EXPLAIN ANALYZE`
/// 写、数据修改型 CTE 都必须被识别为写。判定保守：无法明确判为读的语句一律按写处理。
public enum WriteGate {
    /// 闸门判定：读语句恒放行；写语句按安全模式分流。
    public static func decision(safeMode: ConnectionSafeMode, isWrite: Bool) -> WriteGateDecision {
        guard isWrite else { return .proceed }
        switch safeMode {
        case .off: return .proceed
        case .confirmWrites: return .requiresConfirmation
        case .readOnly: return .blocked
        }
    }

    /// 判断一条语句/命令是否会修改数据或结构。
    ///
    /// SQL 引擎按 `;` 切分后逐句判定——多语句文本中只要任一句是写即视为写，
    /// 避免 `SELECT 1; DELETE FROM t` 这类「读开头、写藏后」绕过闸门。
    public static func isWriteStatement(_ sql: String, type: DatabaseType) -> Bool {
        if type == .redis {
            return isRedisWriteCommand(sql)
        }
        let statements = SQLStatementParser.split(sql)
        return statements.contains { isSingleSQLWriteStatement($0) }
    }

    /// 单条 SQL 语句的写判定（输入已由 ``SQLStatementParser/split(_:)`` 切分）。
    private static func isSingleSQLWriteStatement(_ sql: String) -> Bool {
        let skeleton = SQLStatementParser.stripLiteralsAndComments(sql)
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skeleton.isEmpty else { return false }
        // 去掉前导括号/空白，使 `(SELECT ...)` 这类括号包裹的读语句也能正确识别首词。
        let head = skeleton.drop(while: { $0 == "(" || $0.isWhitespace })
        let verb = String(head.prefix(while: { $0.isLetter || $0 == "_" }))
        switch verb {
        case "SELECT", "SHOW", "DESCRIBE", "DESC", "VALUES", "TABLE":
            return false
        case "BEGIN", "START", "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "ABORT":
            // 事务控制不修改数据本身；readOnly 的事务由 SafeModeTransaction 结构性拦截。
            return false
        case "PRAGMA":
            // `PRAGMA name = value` 是赋值写；`PRAGMA table_info(t)` 等表值函数是读。
            if skeleton.contains("=") { return true }
            if skeleton.contains("(") {
                // 括号形式：已知表值/检查类 pragma 是读，其余（如 journal_mode(WAL)）保守按写。
                return !pragmaReadFunctions.contains(pragmaName(skeleton))
            }
            return false
        case "EXPLAIN":
            // EXPLAIN ANALYZE 会真正执行被解释的语句；含 DML 动词时按写处理。
            if containsWord(skeleton, "ANALYZE") || containsWord(skeleton, "ANALYSE") {
                return containsDMLVerb(skeleton)
            }
            return false
        case "WITH":
            // 数据修改型 CTE（WITH ... INSERT/UPDATE/DELETE）按写处理。
            return containsDMLVerb(skeleton)
        default:
            // INSERT/UPDATE/DELETE/REPLACE/MERGE 及 DDL/DCL/SET 等一律按写保守处理。
            return true
        }
    }

    /// Redis 命令是否为写。采用「读命令白名单」反向判定：未知命令一律按写保守处理。
    static func isRedisWriteCommand(_ command: String) -> Bool {
        let upper = command.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let verb = String(upper.prefix(while: { $0.isLetter || $0 == "_" }))
        return !redisReadCommands.contains(verb)
    }

    private static let redisReadCommands: Set<String> = [
        "GET", "MGET", "GETRANGE", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL",
        "EXPIRETIME", "PEXPIRETIME", "KEYS", "SCAN", "RANDOMKEY", "DUMP", "OBJECT",
        "MEMORY", "INFO", "PING", "ECHO", "TIME", "DBSIZE", "LASTSAVE", "LCS", "SELECT",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSTRLEN",
        "HRANDFIELD", "HSCAN",
        "LRANGE", "LLEN", "LINDEX", "LPOS",
        "SCARD", "SISMEMBER", "SMISMEMBER", "SMEMBERS", "SRANDMEMBER", "SSCAN",
        "SINTER", "SINTERCARD", "SUNION", "SDIFF",
        "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX",
        "ZREVRANGE", "ZREVRANGEBYSCORE", "ZREVRANGEBYLEX", "ZRANK", "ZREVRANK",
        "ZSCORE", "ZMSCORE", "ZSCAN", "ZRANDMEMBER", "ZUNION", "ZINTER", "ZDIFF",
        "BITCOUNT", "BITPOS", "GETBIT", "BITFIELD_RO",
        "XLEN", "XRANGE", "XREVRANGE", "XINFO", "XREAD", "XPENDING", "XAUTOCLAIM",
    ]

    private static let dmlVerbs: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE"]

    /// 骨架中是否以独立单词形式出现 DML 写动词。
    private static func containsDMLVerb(_ skeleton: String) -> Bool {
        dmlVerbs.contains { containsWord(skeleton, $0) }
    }

    /// 整词匹配（`_` 视为词字符，避免 MY_UPDATE 误命中 UPDATE）。
    private static func containsWord(_ skeleton: String, _ word: String) -> Bool {
        skeleton.range(of: "\\b\(word)\\b", options: .regularExpression) != nil
    }

    /// 提取 PRAGMA 名（已大写骨架），跳过可能的 schema 限定符（如 `MAIN.TABLE_INFO`）。
    private static func pragmaName(_ skeleton: String) -> String {
        var rest = Substring(skeleton.dropFirst("PRAGMA".count).trimmingCharacters(in: .whitespaces))
        let first = rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        rest = rest.dropFirst(first.count)
        if rest.first == "." {
            rest = rest.dropFirst()
            return String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
        }
        return String(first)
    }

    /// 括号形式下属于「读」的表值/检查类 pragma；其余括号 pragma 保守按写处理。
    private static let pragmaReadFunctions: Set<String> = [
        "TABLE_INFO", "TABLE_XINFO", "TABLE_LIST", "INDEX_LIST", "INDEX_INFO", "INDEX_XINFO",
        "FOREIGN_KEY_LIST", "FOREIGN_KEY_CHECK", "INTEGRITY_CHECK", "QUICK_CHECK",
        "COMPILE_OPTIONS", "MODULE_LIST", "PRAGMA_LIST", "FUNCTION_LIST", "COLLATION_LIST",
        "DATABASE_LIST", "STATS", "LOCK_STATUS", "FREELIST_COUNT", "PAGE_COUNT",
    ]
}