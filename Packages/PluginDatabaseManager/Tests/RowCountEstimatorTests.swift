import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-6 近似行数计数核心：引擎估算查询生成、估算结果解析（含降级路径）、精确计数 SQL。
@Suite
struct RowCountEstimatorTests {
    @Test func postgresEstimateUsesReltuplesWithSchema() {
        let q = RowCountEstimator.estimateQuery(for: .postgresql, schema: "sales", table: "orders")
        #expect(q != nil)
        #expect(q!.sql.contains("reltuples"))
        #expect(q!.sql.contains("pg_class"))
        #expect(q!.params == [.string("sales"), .string("orders")])
        // 占位符为 PG 编号风格
        #expect(q!.sql.contains("$1"))
        #expect(q!.sql.contains("$2"))
    }

    @Test func postgresEstimateDefaultsToPublicSchema() {
        let q = RowCountEstimator.estimateQuery(for: .postgresql, schema: nil, table: "t")
        #expect(q?.params == [.string("public"), .string("t")])
        let empty = RowCountEstimator.estimateQuery(for: .postgresql, schema: "", table: "t")
        #expect(empty?.params == [.string("public"), .string("t")])
    }

    @Test func mysqlEstimateUsesInformationSchema() {
        let q = RowCountEstimator.estimateQuery(for: .mysql, schema: "testdb", table: "items")
        #expect(q != nil)
        #expect(q!.sql.contains("information_schema.TABLES"))
        #expect(q!.sql.contains("TABLE_ROWS"))
        #expect(q!.params == [.string("testdb"), .string("items")])
        #expect(q!.sql.contains("?"))
    }

    @Test func mysqlEstimateWithoutDatabaseFallsBack() {
        #expect(RowCountEstimator.estimateQuery(for: .mysql, schema: nil, table: "t") == nil)
        #expect(RowCountEstimator.estimateQuery(for: .mysql, schema: "", table: "t") == nil)
    }

    @Test func sqliteAndRedisHaveNoEstimate() {
        #expect(RowCountEstimator.estimateQuery(for: .sqlite, schema: nil, table: "t") == nil)
        #expect(RowCountEstimator.estimateQuery(for: .redis, schema: nil, table: "t") == nil)
    }

    @Test func interpretEstimateParsesNumericForms() {
        #expect(RowCountEstimator.interpretEstimate(.integer(100)) == 100)
        #expect(RowCountEstimator.interpretEstimate(.double(100.9)) == 100)
        #expect(RowCountEstimator.interpretEstimate(.string("55")) == 55)
        #expect(RowCountEstimator.interpretEstimate(.integer(0)) == 0)
    }

    @Test func interpretEstimateRejectsNegativeAndNull() {
        // PG 未 ANALYZE 的 reltuples = -1 → 降级精确计数
        #expect(RowCountEstimator.interpretEstimate(.integer(-1)) == nil)
        #expect(RowCountEstimator.interpretEstimate(.double(-1)) == nil)
        #expect(RowCountEstimator.interpretEstimate(.null) == nil)
        #expect(RowCountEstimator.interpretEstimate(.string("abc")) == nil)
    }

    @Test func exactQueryWithAndWithoutWhere() {
        #expect(RowCountEstimator.exactQuery(tableExpr: "\"t\"", whereClause: nil) == "SELECT COUNT(*) FROM \"t\"")
        #expect(RowCountEstimator.exactQuery(tableExpr: "\"t\"", whereClause: "") == "SELECT COUNT(*) FROM \"t\"")
        #expect(RowCountEstimator.exactQuery(tableExpr: "\"t\"", whereClause: "\"x\" > $1") == "SELECT COUNT(*) FROM \"t\" WHERE \"x\" > $1")
    }
}