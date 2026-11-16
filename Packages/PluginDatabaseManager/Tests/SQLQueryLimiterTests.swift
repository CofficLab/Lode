import Foundation
import Testing
@testable import DatabaseManagerPlugin

@Suite struct SQLQueryLimiterTests {
    @Test func injectsLimitIntoPlainSelect() {
        let result = SQLQueryLimiter.apply("SELECT * FROM users", limit: 1000)
        #expect(result.sql == "SELECT * FROM users\nLIMIT 1000")
        #expect(result.injectedLimit == 1000)
        #expect(result.baseSQL == "SELECT * FROM users")
    }

    @Test func stripsTrailingSemicolonBeforeInjecting() {
        let result = SQLQueryLimiter.apply("  SELECT * FROM users;  ", limit: 50)
        #expect(result.sql == "SELECT * FROM users\nLIMIT 50")
        #expect(result.baseSQL == "SELECT * FROM users")
    }

    @Test func respectsUserLimit() {
        let result = SQLQueryLimiter.apply("SELECT * FROM users LIMIT 5", limit: 1000)
        #expect(result.sql == "SELECT * FROM users LIMIT 5")
        #expect(result.injectedLimit == nil)
        #expect(result.baseSQL == nil)
    }

    @Test func respectsUserFetchFirst() {
        let result = SQLQueryLimiter.apply("SELECT * FROM users FETCH FIRST 3 ROWS ONLY", limit: 1000)
        #expect(result.injectedLimit == nil)
    }

    @Test func subqueryLimitDoesNotCount() {
        let result = SQLQueryLimiter.apply(
            "SELECT * FROM (SELECT id FROM t LIMIT 3) sub", limit: 100
        )
        #expect(result.injectedLimit == 100)
        #expect(result.sql.hasSuffix("LIMIT 100"))
    }

    @Test func limitInsideStringLiteralDoesNotCount() {
        let result = SQLQueryLimiter.apply("SELECT 'LIMIT 5' AS label FROM t", limit: 100)
        #expect(result.injectedLimit == 100)
    }

    @Test func limitInsideCommentDoesNotCount() {
        let result = SQLQueryLimiter.apply("SELECT * FROM t -- LIMIT 5\n", limit: 100)
        #expect(result.injectedLimit == 100)
        // 注入必须换行开头，否则落进行注释。
        #expect(result.sql.contains("\nLIMIT 100"))
    }

    @Test func insertsBeforeExistingOffset() {
        let result = SQLQueryLimiter.apply("SELECT * FROM t OFFSET 10", limit: 100)
        #expect(result.sql == "SELECT * FROM t LIMIT 100 OFFSET 10")
    }

    @Test func insertsBeforeForUpdate() {
        let result = SQLQueryLimiter.apply("SELECT * FROM t FOR UPDATE", limit: 100)
        #expect(result.sql == "SELECT * FROM t LIMIT 100 FOR UPDATE")
    }

    @Test func forNoKeyUpdateIsNotTreatedAsWrite() {
        let result = SQLQueryLimiter.apply("SELECT * FROM t FOR NO KEY UPDATE", limit: 100)
        #expect(result.sql == "SELECT * FROM t LIMIT 100 FOR NO KEY UPDATE")
        #expect(result.injectedLimit == 100)
    }

    @Test func injectsIntoWithCTE() {
        let result = SQLQueryLimiter.apply(
            "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent", limit: 200
        )
        #expect(result.injectedLimit == 200)
        #expect(result.sql.hasSuffix("LIMIT 200"))
    }

    @Test func skipsDataModifyingCTE() {
        let sql = "WITH src AS (SELECT 1 AS id) INSERT INTO t SELECT * FROM src"
        let result = SQLQueryLimiter.apply(sql, limit: 100)
        #expect(result.injectedLimit == nil)
        #expect(result.sql == sql)
    }

    @Test func skipsNonSelectStatements() {
        for sql in ["UPDATE t SET x = 1", "PRAGMA table_info(t)", "SHOW TABLES", "DELETE FROM t"] {
            let result = SQLQueryLimiter.apply(sql, limit: 100)
            #expect(result.injectedLimit == nil)
            #expect(result.sql == sql)
        }
    }

    @Test func skipsMultipleStatements() {
        let sql = "SELECT 1; SELECT 2"
        let result = SQLQueryLimiter.apply(sql, limit: 100)
        #expect(result.injectedLimit == nil)
        #expect(result.sql == sql)
    }

    @Test func unionGetsSingleTrailingLimit() {
        let result = SQLQueryLimiter.apply("SELECT 1 UNION SELECT 2", limit: 10)
        #expect(result.sql == "SELECT 1 UNION SELECT 2\nLIMIT 10")
    }

    @Test func zeroLimitDisablesInjection() {
        let result = SQLQueryLimiter.apply("SELECT * FROM t", limit: 0)
        #expect(result.injectedLimit == nil)
    }
}