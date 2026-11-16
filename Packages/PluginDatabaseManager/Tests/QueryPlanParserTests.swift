import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-2 EXPLAIN 计划解析离线单测：三引擎合成夹具 → 统一 QueryPlan 树。
// 覆盖 PG JSON（含 ANALYZE 字段）、MySQL JSON（nested_loop/ordering）与表格回退、
// SQLite QUERY PLAN（含深层树/多根）、瓶颈权重、解析失败保留 rawText。

@Suite(.serialized)
struct PostgreSQLPlanParserTests {
    private let json = """
    [{"Plan":{"Node Type":"Aggregate","Strategy":"Plain","Startup Cost":0.0,"Total Cost":12.5,"Plan Rows":1,"Plan Width":8,"Actual Startup Time":0.05,"Actual Total Time":0.08,"Actual Rows":1,"Actual Loops":1,"Plans":[{"Node Type":"Seq Scan","Relation Name":"users","Alias":"u","Startup Cost":0.0,"Total Cost":10.0,"Plan Rows":100,"Plan Width":4,"Actual Total Time":0.5,"Actual Rows":100,"Actual Loops":1,"Filter":"(age > 18)"}]},"Planning Time":0.12,"Execution Time":0.2}]
    """

    @Test func parsesNestedPlanWithAnalyzeFields() throws {
        let plan = PostgreSQLPlanParser.parse(json, analyze: true)
        #expect(plan.engine == .postgresql)
        #expect(plan.analyze)
        #expect(plan.planningTimeMs == 0.12)
        #expect(plan.executionTimeMs == 0.2)
        let root = try #require(plan.roots.first)
        #expect(root.operation == "Aggregate")
        #expect(root.estimatedTotalCost == 12.5)
        #expect(root.actualTotalTimeMs == 0.08)
        #expect(root.actualRows == 1)
        #expect(root.details.contains("Strategy: Plain"))
        let child = try #require(root.children.first)
        #expect(child.id == "0.0")
        #expect(child.operation == "Seq Scan")
        #expect(child.relation == "users")
        #expect(child.alias == "u")
        #expect(child.estimatedRows == 100)
        #expect(child.actualRows == 100)
        #expect(child.filter == "(age > 18)")
    }

    @Test func bottleneckPicksHighestActualTime() throws {
        let plan = PostgreSQLPlanParser.parse(json, analyze: true)
        // 子节点实际时间 0.5 > 根 0.08 → 瓶颈在子节点。
        #expect(plan.bottleneckNodeID == "0.0")
    }

    @Test func bottleneckFallsBackToEstimatedCostWithoutAnalyze() throws {
        // 普通 EXPLAIN（无 ANALYZE）不含 Actual* 字段，瓶颈按估算总代价。
        let estimatedOnly = """
        [{"Plan":{"Node Type":"Aggregate","Startup Cost":0.0,"Total Cost":12.5,"Plan Rows":1,"Plan Width":8,"Plans":[{"Node Type":"Seq Scan","Relation Name":"users","Startup Cost":0.0,"Total Cost":10.0,"Plan Rows":100,"Plan Width":4}]}}]
        """
        let plan = PostgreSQLPlanParser.parse(estimatedOnly, analyze: false)
        #expect(plan.roots.first?.actualTotalTimeMs == nil)
        // 根 12.5 > 子 10.0。
        #expect(plan.bottleneckNodeID == "0")
    }

    @Test func invalidJSONKeepsRawText() {
        let plan = PostgreSQLPlanParser.parse("not json", analyze: false)
        #expect(plan.isEmpty)
        #expect(plan.rawText == "not json")
    }
}

@Suite(.serialized)
struct MySQLPlanParserTests {
    @Test func parsesNestedLoopJoin() throws {
        let json = """
        {"query_block":{"select_id":1,"cost_info":{"query_cost":"21.00"},"nested_loop":[{"table":{"table_name":"u","access_type":"ALL","rows_examined_per_scan":100,"rows_produced_per_join":100,"filtered":"100.00","cost_info":{"read_cost":"1.00","eval_cost":"10.00","prefix_cost":"11.00"},"used_columns":["id","age"]}},{"table":{"table_name":"o","access_type":"ref","key":"idx_user","used_key_parts":["user_id"],"rows_examined_per_scan":2,"filtered":"100.00","cost_info":{"read_cost":"1.00","eval_cost":"2.00","prefix_cost":"21.00"},"attached_condition":"(o.user_id = u.id)"}}]}}
        """
        let plan = MySQLPlanParser.parseJSON(json)
        let root = try #require(plan.roots.first)
        #expect(root.operation == "Query Block")
        #expect(root.estimatedTotalCost == 21.0)
        #expect(root.details.contains("select_id: 1"))
        #expect(root.children.count == 2)
        let first = root.children[0]
        #expect(first.operation == "ALL")
        #expect(first.relation == "u")
        #expect(first.estimatedRows == 100)
        #expect(first.estimatedTotalCost == 11.0)
        let second = root.children[1]
        #expect(second.operation == "ref")
        #expect(second.relation == "o")
        #expect(second.index == "idx_user")
        #expect(second.filter == "(o.user_id = u.id)")
        #expect(second.details.contains("key: idx_user"))
        #expect(second.details.contains("used_key_parts: user_id"))
    }

    @Test func parsesOrderingOperationWithFilesort() throws {
        let json = """
        {"query_block":{"select_id":1,"ordering_operation":{"using_filesort":true,"cost_info":{"sort_cost":"5.00"},"table":{"table_name":"t","access_type":"index","key":"PRIMARY","rows_examined_per_scan":10,"cost_info":{"prefix_cost":"12.00"}}}}}
        """
        let plan = MySQLPlanParser.parseJSON(json)
        let root = try #require(plan.roots.first)
        let ordering = try #require(root.children.first { $0.operation == "Ordering" })
        #expect(ordering.details.contains("using_filesort"))
        let table = try #require(ordering.children.first)
        #expect(table.relation == "t")
        #expect(table.operation == "index")
        #expect(table.estimatedTotalCost == 12.0)
    }

    @Test func parsesSingleTableQueryBlock() throws {
        let json = """
        {"query_block":{"select_id":1,"cost_info":{"query_cost":"1.20"},"table":{"table_name":"dual","access_type":"system","rows_examined_per_scan":1,"cost_info":{"prefix_cost":"1.20"}}}}
        """
        let plan = MySQLPlanParser.parseJSON(json)
        let root = try #require(plan.roots.first)
        let table = try #require(root.children.first)
        #expect(table.relation == "dual")
        #expect(table.operation == "system")
    }

    @Test func tabularFallbackMapsRows() throws {
        let result = QueryResult(
            columns: ["id", "select_type", "table", "type", "possible_keys", "key", "key_len", "ref", "rows", "filtered", "Extra"],
            rows: [[.integer(1), .string("SIMPLE"), .string("u"), .string("ALL"), .null, .null, .null, .null, .integer(100), .string("100.00"), .string("Using where")]],
            rowsAffected: 0
        )
        let plan = MySQLPlanParser.parseTabular(result)
        let node = try #require(plan.roots.first)
        #expect(node.operation == "ALL")
        #expect(node.relation == "u")
        #expect(node.estimatedRows == 100)
        #expect(node.filter == "Using where")
        #expect(node.details.contains("select_type: SIMPLE"))
    }

    @Test func invalidJSONKeepsRawText() {
        let plan = MySQLPlanParser.parseJSON("oops")
        #expect(plan.isEmpty)
        #expect(plan.rawText == "oops")
    }
}

@Suite(.serialized)
struct SQLitePlanParserTests {
    @Test func parsesScanSearchWithIndex() throws {
        let result = QueryResult(
            columns: ["id", "parent", "notused", "detail"],
            rows: [
                [.integer(2), .integer(0), .integer(0), .string("SCAN u")],
                [.integer(5), .integer(2), .integer(0), .string("SEARCH o USING INDEX idx_user (user_id=?)")]
            ],
            rowsAffected: 0
        )
        let plan = SQLitePlanParser.parse(result)
        #expect(plan.roots.count == 1)
        let root = try #require(plan.roots.first)
        #expect(root.id == "2")
        #expect(root.operation == "SCAN u")
        #expect(root.relation == "u")
        let child = try #require(root.children.first)
        #expect(child.id == "5")
        #expect(child.relation == "o")
        #expect(child.index == "idx_user")
        #expect(child.filter == "(user_id=?)")
    }

    @Test func buildsDeepCompoundTreeWithoutLosingDescendants() throws {
        let result = QueryResult(
            columns: ["id", "parent", "notused", "detail"],
            rows: [
                [.integer(1), .integer(0), .integer(0), .string("COMPOUND QUERY")],
                [.integer(2), .integer(1), .integer(0), .string("LEFT-MOST SUBQUERY")],
                [.integer(3), .integer(2), .integer(0), .string("SCAN a")],
                [.integer(4), .integer(1), .integer(0), .string("MERGE (UNION ALL)")],
                [.integer(5), .integer(4), .integer(0), .string("SCAN b")]
            ],
            rowsAffected: 0
        )
        let plan = SQLitePlanParser.parse(result)
        let root = try #require(plan.roots.first)
        #expect(root.operation == "COMPOUND QUERY")
        #expect(root.children.count == 2)
        let left = root.children[0]
        #expect(left.operation == "LEFT-MOST SUBQUERY")
        #expect(left.children.first?.relation == "a")
        let merge = root.children[1]
        #expect(merge.operation == "MERGE (UNION ALL)")
        #expect(merge.children.first?.relation == "b")
        // 深层后代不丢失。
        #expect(plan.allNodes().count == 5)
    }

    @Test func detailExtractionHandlesIndexVariants() {
        #expect(SQLitePlanParser.parseDetail("SCAN t").relation == "t")
        #expect(SQLitePlanParser.parseDetail("SCAN CONSTANT ROW").relation == nil)
        #expect(SQLitePlanParser.parseDetail("SEARCH t USING COVERING INDEX idx (x=?)").index == "idx")
        #expect(SQLitePlanParser.parseDetail("SEARCH t USING INTEGER PRIMARY KEY (rowid=?)").index == "INTEGER PRIMARY KEY")
        #expect(SQLitePlanParser.parseDetail("USE TEMP B-TREE FOR ORDER BY").relation == nil)
        #expect(SQLitePlanParser.parseDetail("SEARCH t USING INDEX idx (a=? AND b=?)").filter == "(a=? AND b=?)")
    }

    @Test func emptyResultProducesEmptyPlan() {
        let plan = SQLitePlanParser.parse(QueryResult(columns: ["id", "parent", "notused", "detail"], rows: [], rowsAffected: 0))
        #expect(plan.isEmpty)
    }
}

@Suite(.serialized)
struct QueryPlanBottleneckTests {
    @Test func weightPrefersActualTimeThenCostThenRows() {
        let actual = QueryPlanNode(id: "a", operation: "x", actualTotalTimeMs: 2.0, actualLoops: 3)
        #expect(actual.bottleneckWeight == 6.0)
        let cost = QueryPlanNode(id: "b", operation: "x", estimatedTotalCost: 50)
        #expect(cost.bottleneckWeight == 50)
        let rows = QueryPlanNode(id: "c", operation: "x", estimatedRows: 7)
        #expect(rows.bottleneckWeight == 7)
    }

    @Test func emptyPlanHasNoBottleneck() {
        let plan = QueryPlan(engine: .postgresql)
        #expect(plan.bottleneckNodeID == nil)
        #expect(plan.isEmpty)
    }
}