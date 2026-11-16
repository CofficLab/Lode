import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-2 EXPLAIN 执行接线离线单测：语句拼装、写闸门识别（ANALYZE+DML）、结果解析分发。
// 真实引擎的端到端 EXPLAIN 与 ANALYZE 闸门见 QueryPlanIntegrationTests。

@Suite(.serialized)
struct ExplainStatementTests {
    @Test func buildsPerEngineSyntax() {
        #expect(DatabaseViewModel.explainStatement("SELECT 1", type: .postgresql, analyze: false) == "EXPLAIN (FORMAT JSON) SELECT 1")
        #expect(DatabaseViewModel.explainStatement("SELECT 1", type: .postgresql, analyze: true) == "EXPLAIN (ANALYZE, FORMAT JSON) SELECT 1")
        #expect(DatabaseViewModel.explainStatement("SELECT 1", type: .mysql, analyze: false) == "EXPLAIN FORMAT=JSON SELECT 1")
        #expect(DatabaseViewModel.explainStatement("SELECT 1", type: .sqlite, analyze: false) == "EXPLAIN QUERY PLAN SELECT 1")
    }

    @Test func analyzeOnlyAppliesToPostgreSQL() {
        // MySQL/SQLite 即便请求 analyze 也不加 ANALYZE（仅 PG 支持）。
        #expect(DatabaseViewModel.explainStatement("SELECT 1", type: .mysql, analyze: true) == "EXPLAIN FORMAT=JSON SELECT 1")
        #expect(DatabaseViewModel.explainStatement("SELECT 1", type: .sqlite, analyze: true) == "EXPLAIN QUERY PLAN SELECT 1")
    }
}

@Suite(.serialized)
struct ExplainWriteGateTests {
    @Test func plainExplainIsRead() {
        #expect(WriteGate.isWriteStatement("EXPLAIN (FORMAT JSON) SELECT * FROM t", type: .postgresql) == false)
        #expect(WriteGate.isWriteStatement("EXPLAIN FORMAT=JSON SELECT * FROM t", type: .mysql) == false)
        #expect(WriteGate.isWriteStatement("EXPLAIN QUERY PLAN SELECT * FROM t", type: .sqlite) == false)
    }

    @Test func analyzeSelectIsReadButAnalyzeDMLIsWrite() {
        // ANALYZE 真实执行：SELECT 仍只读放行，DML 必须被识别为写以触发闸门。
        #expect(WriteGate.isWriteStatement("EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM t", type: .postgresql) == false)
        #expect(WriteGate.isWriteStatement("EXPLAIN (ANALYZE, FORMAT JSON) DELETE FROM t", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("EXPLAIN (ANALYZE, FORMAT JSON) UPDATE t SET x = 1", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("EXPLAIN (ANALYZE, FORMAT JSON) INSERT INTO t VALUES (1)", type: .postgresql) == true)
    }
}

@Suite(.serialized)
struct ExplainPlanDispatchTests {
    @Test func postgresSingleRowJSONParsesToTree() throws {
        let json = """
        [{"Plan":{"Node Type":"Seq Scan","Relation Name":"t","Total Cost":5.0,"Plan Rows":10}}]
        """
        let result = QueryResult(columns: ["QUERY PLAN"], rows: [[.string(json)]], rowsAffected: 0)
        let plan = DatabaseViewModel.parsePlan(result, type: .postgresql, analyze: false)
        #expect(plan.engine == .postgresql)
        #expect(plan.roots.first?.operation == "Seq Scan")
        #expect(plan.roots.first?.relation == "t")
    }

    @Test func mysqlSingleColumnJSONParsesToTree() throws {
        let json = """
        {"query_block":{"select_id":1,"table":{"table_name":"t","access_type":"ALL","rows_examined_per_scan":10}}}
        """
        let result = QueryResult(columns: ["EXPLAIN"], rows: [[.string(json)]], rowsAffected: 0)
        let plan = DatabaseViewModel.parsePlan(result, type: .mysql, analyze: false)
        #expect(plan.engine == .mysql)
        #expect(plan.roots.first?.children.first?.relation == "t")
    }

    @Test func mysqlTabularFallsBackWhenNotJSON() throws {
        let result = QueryResult(
            columns: ["id", "select_type", "table", "type", "rows", "Extra"],
            rows: [[.integer(1), .string("SIMPLE"), .string("t"), .string("ALL"), .integer(10), .string("Using where")]],
            rowsAffected: 0
        )
        let plan = DatabaseViewModel.parsePlan(result, type: .mysql, analyze: false)
        #expect(plan.roots.first?.operation == "ALL")
        #expect(plan.roots.first?.relation == "t")
    }

    @Test func sqliteRowsParseToTree() throws {
        let result = QueryResult(
            columns: ["id", "parent", "notused", "detail"],
            rows: [[.integer(2), .integer(0), .integer(0), .string("SCAN t")]],
            rowsAffected: 0
        )
        let plan = DatabaseViewModel.parsePlan(result, type: .sqlite, analyze: false)
        #expect(plan.engine == .sqlite)
        #expect(plan.roots.first?.relation == "t")
    }

    @Test func postgresDataColumnJSONParses() throws {
        // 某些驱动把 JSON 文本按 .data 返回，SchemaRowDecoder 须按 UTF-8 还原。
        let json = """
        [{"Plan":{"Node Type":"Result","Total Cost":0.01,"Plan Rows":1}}]
        """
        let result = QueryResult(columns: ["QUERY PLAN"], rows: [[.data(Data(json.utf8))]], rowsAffected: 0)
        let plan = DatabaseViewModel.parsePlan(result, type: .postgresql, analyze: false)
        #expect(plan.roots.first?.operation == "Result")
    }
}