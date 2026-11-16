import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P1-7 写权限闸门单元测试：
// - 三档安全模式 × 读/写 的判定矩阵（proceed / requiresConfirmation / blocked）；
// - 写语句识别器：DML/DDL/DCL、RETURNING 写、数据修改型 CTE、EXPLAIN ANALYZE 写、
//   PRAGMA 赋值写、多语句「读开头写藏后」、字面量/注释剥离、事务控制非写；
// - Redis 读命令白名单反向判定；
// - DatabaseConfig.safeMode 经 options 持久化与回退。

@Suite
struct WriteGateTests {
    // MARK: - 判定矩阵（三档 × 读/写）

    @Test
    func decisionMatrix() {
        // 读语句：任何档位都放行。
        for mode in ConnectionSafeMode.allCases {
            #expect(WriteGate.decision(safeMode: mode, isWrite: false) == .proceed)
        }
        // 写语句：off 放行、confirm 需确认、readOnly 拒绝。
        #expect(WriteGate.decision(safeMode: .off, isWrite: true) == .proceed)
        #expect(WriteGate.decision(safeMode: .confirmWrites, isWrite: true) == .requiresConfirmation)
        #expect(WriteGate.decision(safeMode: .readOnly, isWrite: true) == .blocked)
    }

    // MARK: - SQL 读语句（不应被拦）

    @Test(arguments: [DatabaseType.sqlite, .mysql, .postgresql])
    func sqlReadStatementsAreNotWrites(type: DatabaseType) {
        let reads = [
            "SELECT * FROM t",
            "select id, name from users where id = 1",
            "  SELECT 1  ",
            "(SELECT 1)",
            "SHOW TABLES",
            "DESCRIBE t",
            "DESC t",
            "EXPLAIN SELECT * FROM t",
            "EXPLAIN ANALYZE SELECT * FROM t",
            "VALUES (1), (2)",
            "TABLE t",
            "WITH cte AS (SELECT 1 AS x) SELECT * FROM cte",
            "SELECT 'DROP TABLE t' AS word",
            "SELECT * FROM t WHERE note = 'UPDATE me'",
            "/* just a comment */",
            "",
            "   ",
        ]
        for sql in reads {
            #expect(WriteGate.isWriteStatement(sql, type: type) == false, "read misclassified as write: \(sql)")
        }
    }

    @Test
    func sqlitePragmaReadIsNotWrite() {
        #expect(WriteGate.isWriteStatement("PRAGMA table_info(t)", type: .sqlite) == false)
        #expect(WriteGate.isWriteStatement("PRAGMA foreign_keys", type: .sqlite) == false)
        #expect(WriteGate.isWriteStatement("PRAGMA index_list(t)", type: .sqlite) == false)
        #expect(WriteGate.isWriteStatement("PRAGMA main.table_info(t)", type: .sqlite) == false)
        #expect(WriteGate.isWriteStatement("PRAGMA integrity_check", type: .sqlite) == false)
    }

    @Test
    func sqlitePragmaParenAssignmentIsWrite() {
        // 括号赋值形式（非表值读函数）保守按写处理。
        #expect(WriteGate.isWriteStatement("PRAGMA journal_mode(WAL)", type: .sqlite) == true)
        #expect(WriteGate.isWriteStatement("PRAGMA foreign_keys(ON)", type: .sqlite) == true)
    }

    @Test
    func transactionControlIsNotWrite() {
        for sql in ["BEGIN", "BEGIN TRANSACTION", "START TRANSACTION", "COMMIT", "ROLLBACK", "SAVEPOINT sp", "RELEASE sp"] {
            #expect(WriteGate.isWriteStatement(sql, type: .postgresql) == false, "tx control treated as write: \(sql)")
        }
    }

    // MARK: - SQL 写语句（必须被拦）

    @Test(arguments: [DatabaseType.sqlite, .mysql, .postgresql])
    func sqlWriteStatementsAreWrites(type: DatabaseType) {
        let writes = [
            "INSERT INTO t (a) VALUES (1)",
            "UPDATE t SET a = 1 WHERE id = 2",
            "DELETE FROM t WHERE id = 2",
            "REPLACE INTO t (a) VALUES (1)",
            "CREATE TABLE t (id INTEGER)",
            "ALTER TABLE t ADD COLUMN b TEXT",
            "DROP TABLE t",
            "TRUNCATE TABLE t",
            "GRANT SELECT ON t TO u",
            "SET autocommit = 0",
            "insert into t values (1)",
            "/* c */ UPDATE t SET a = 1",
            "UPDATE t SET a = 1 -- trailing comment",
        ]
        for sql in writes {
            #expect(WriteGate.isWriteStatement(sql, type: type) == true, "write missed: \(sql)")
        }
    }

    @MainActor
    @Test
    func returningWritesAreWrites() {
        // RETURNING 写会被 isReadStatement 当作读以展示返回行，但闸门必须识别为写。
        #expect(WriteGate.isWriteStatement("INSERT INTO t (a) VALUES (1) RETURNING id", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("UPDATE t SET a = 1 WHERE id = 2 RETURNING *", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("DELETE FROM t WHERE id = 2 RETURNING id", type: .postgresql) == true)
        // 与路由判定对照：这些语句确实走 query 路径。
        #expect(DatabaseViewModel.isReadStatement("DELETE FROM t WHERE id = 2 RETURNING id", type: .postgresql) == true)
    }

    @Test
    func dataModifyingCTEIsWrite() {
        #expect(WriteGate.isWriteStatement("WITH c AS (SELECT 1) INSERT INTO t SELECT * FROM c", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("WITH u AS (UPDATE t SET a = 1 RETURNING *) SELECT * FROM u", type: .postgresql) == true)
    }

    @Test
    func explainAnalyzeWriteIsWrite() {
        #expect(WriteGate.isWriteStatement("EXPLAIN ANALYZE DELETE FROM t", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("EXPLAIN (ANALYZE) INSERT INTO t VALUES (1)", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("EXPLAIN ANALYSE UPDATE t SET a = 1", type: .postgresql) == true)
        // 纯 EXPLAIN（不执行）与 EXPLAIN ANALYZE SELECT 仍是读。
        #expect(WriteGate.isWriteStatement("EXPLAIN DELETE FROM t", type: .postgresql) == false)
        #expect(WriteGate.isWriteStatement("EXPLAIN ANALYZE SELECT * FROM t", type: .postgresql) == false)
    }

    @Test
    func sqlitePragmaAssignmentIsWrite() {
        #expect(WriteGate.isWriteStatement("PRAGMA query_only = ON", type: .sqlite) == true)
        #expect(WriteGate.isWriteStatement("PRAGMA user_version = 5", type: .sqlite) == true)
        #expect(WriteGate.isWriteStatement("PRAGMA foreign_keys(1)", type: .sqlite) == true)
    }

    @Test
    func multiStatementHidingWriteIsWrite() {
        #expect(WriteGate.isWriteStatement("SELECT 1; DELETE FROM t", type: .sqlite) == true)
        #expect(WriteGate.isWriteStatement("SELECT 1; SELECT 2", type: .sqlite) == false)
        #expect(WriteGate.isWriteStatement("SELECT ';' AS s", type: .sqlite) == false)
        #expect(WriteGate.isWriteStatement("SELECT 1; UPDATE t SET a = 1; SELECT 2", type: .mysql) == true)
    }

    // MARK: - Redis

    @Test
    func redisReadCommandsAreNotWrites() {
        for cmd in ["GET k", "get k", "SCAN 0 MATCH * COUNT 50", "HGETALL h", "LRANGE l 0 -1",
                    "SMEMBERS s", "ZRANGE z 0 -1", "EXISTS k", "TTL k", "PING", "INFO", "DBSIZE",
                    "HGET h f", "MGET a b", "ZSCORE z m", "LLEN l", "TYPE k"] {
            #expect(WriteGate.isWriteStatement(cmd, type: .redis) == false, "redis read treated as write: \(cmd)")
        }
    }

    @Test
    func redisWriteCommandsAreWrites() {
        for cmd in ["SET k v", "set k v", "DEL k", "HSET h f v", "LPUSH l v", "SADD s m",
                    "ZADD z 1 m", "EXPIRE k 10", "INCR k", "FLUSHDB", "FLUSHALL", "APPEND k v",
                    "UNLINK k", "RENAME a b", "CONFIG SET maxmemory 100"] {
            #expect(WriteGate.isWriteStatement(cmd, type: .redis) == true, "redis write missed: \(cmd)")
        }
    }

    @MainActor
    @Test
    func redisReadClassificationMatchesGate() {
        // 读路径判定必须与写闸门同一事实源，杜绝两份前缀列表漂移。
        for cmd in ["GET k", "HGETALL h", "TTL k", "TYPE k", "XRANGE s - +", "MGET a b",
                    "GETBIT k 0", "ZRANGE z 0 -1 WITHSCORES", "SCAN 0", "SET k v", "DEL k",
                    "HSET h f v", "EXPIRE k 10", "FLUSHDB", "SOMEUNKNOWNCMD x"] {
            #expect(
                DatabaseViewModel.isReadStatement(cmd, type: .redis) == !WriteGate.isWriteStatement(cmd, type: .redis),
                "read classification diverges from gate: \(cmd)"
            )
        }
    }

    @MainActor
    @Test
    func redisTypedReadsUseQueryPath() {
        // 回归守卫：这些读命令旧前缀列表会误判为写，导致结果被丢弃（只显示 Rows affected）。
        for cmd in ["HGETALL h", "TTL k", "PTTL k", "TYPE k", "XRANGE s - +", "MGET a b",
                    "HKEYS h", "HVALS h", "LLEN l", "ZSCORE z m", "GETBIT k 0", "STRLEN k"] {
            #expect(DatabaseViewModel.isReadStatement(cmd, type: .redis), "redis read dropped to write path: \(cmd)")
        }
    }

    // MARK: - 配置持久化

    @Test
    func safeModeDefaultsToOff() {
        let config = DatabaseConfig(name: "c", type: .sqlite, database: ":memory:")
        #expect(config.safeMode == .off)
        #expect(config.options == nil)
    }

    @Test
    func safeModeRoundTripsThroughOptions() {
        let base = DatabaseConfig(name: "c", type: .postgresql, host: "h", database: "d")
        for mode in ConnectionSafeMode.allCases {
            let applied = base.withSafeMode(mode)
            #expect(applied.safeMode == mode)
            // 其余字段不变。
            #expect(applied.id == base.id)
            #expect(applied.name == base.name)
            #expect(applied.type == base.type)
        }
        // off 移除键，回退默认（不残留空 options）。
        let off = base.withSafeMode(.readOnly).withSafeMode(.off)
        #expect(off.safeMode == .off)
        #expect(off.options == nil)
    }

    @Test
    func safeModePreservesOtherOptions() {
        let base = DatabaseConfig(name: "c", type: .mysql, host: "h", database: "d", options: ["ssl": "require", "connectTimeoutSeconds": "5"])
        let applied = base.withSafeMode(.confirmWrites)
        #expect(applied.safeMode == .confirmWrites)
        #expect(applied.sslOption == .require)
        #expect(applied.connectTimeoutSeconds == 5)
        let removed = applied.withSafeMode(.off)
        #expect(removed.sslOption == .require)
        #expect(removed.connectTimeoutSeconds == 5)
    }

    @Test
    func unknownSafeModeRawValueFallsBackToOff() {
        let config = DatabaseConfig(name: "c", type: .sqlite, database: ":memory:", options: ["safeMode": "bogus"])
        #expect(config.safeMode == .off)
    }

    @Test
    func safeModeSurvivesCodable() throws {
        let config = DatabaseConfig(name: "c", type: .sqlite, database: ":memory:").withSafeMode(.readOnly)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DatabaseConfig.self, from: data)
        #expect(decoded.safeMode == .readOnly)
    }
}