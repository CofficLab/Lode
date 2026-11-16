import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-6 keyset 分页核心：适用性判定、游标提取边界、WHERE 合并与参数编号续接。
@Suite
struct KeysetPaginatorTests {
    private func quote(_ s: String) -> String { "\"\(s)\"" }

    @Test func applicabilityRequiresSingleMatchingKeyColumn() {
        #expect(KeysetPaginator.isApplicable(orderColumn: nil, keyColumns: ["id"]) == false)
        #expect(KeysetPaginator.isApplicable(orderColumn: "id", keyColumns: []) == false)
        #expect(KeysetPaginator.isApplicable(orderColumn: "id", keyColumns: ["id", "seq"]) == false)
        #expect(KeysetPaginator.isApplicable(orderColumn: "name", keyColumns: ["id"]) == false)
        #expect(KeysetPaginator.isApplicable(orderColumn: "id", keyColumns: ["id"]) == true)
    }

    @Test func cursorExtractsLastRowValue() {
        let result = QueryResult(columns: ["id", "name"], rows: [[.integer(1), .string("a")], [.integer(2), .string("b")]], rowsAffected: 2)
        let asc = KeysetPaginator.cursor(from: result, column: "id", ascending: true)
        #expect(asc == KeysetCursor(column: "id", value: .integer(2), ascending: true))
        let desc = KeysetPaginator.cursor(from: result, column: "id", ascending: false)
        #expect(desc?.ascending == false)
        #expect(desc?.value == .integer(2))
    }

    @Test func cursorBoundariesReturnNil() {
        let empty = QueryResult(columns: ["id"], rows: [], rowsAffected: 0)
        #expect(KeysetPaginator.cursor(from: empty, column: "id", ascending: true) == nil)
        let missing = QueryResult(columns: ["name"], rows: [[.string("a")]], rowsAffected: 1)
        #expect(KeysetPaginator.cursor(from: missing, column: "id", ascending: true) == nil)
        let nullKey = QueryResult(columns: ["id"], rows: [[.null]], rowsAffected: 1)
        #expect(KeysetPaginator.cursor(from: nullKey, column: "id", ascending: true) == nil)
    }

    @Test func combineWhereWithoutCursorPassesFilterThrough() {
        let out = KeysetPaginator.combineWhere(filterClause: "\"x\" = $1", filterParams: [.integer(5)], cursor: nil, dialect: .postgresql, quote: quote)
        #expect(out.clause == "\"x\" = $1")
        #expect(out.params == [.integer(5)])
        let none = KeysetPaginator.combineWhere(filterClause: nil, filterParams: [], cursor: nil, dialect: .sqlite, quote: quote)
        #expect(none.clause == nil)
        #expect(none.params.isEmpty)
    }

    @Test func combineWherePostgresContinuesParameterNumbering() {
        let cursor = KeysetCursor(column: "id", value: .integer(10), ascending: true)
        let out = KeysetPaginator.combineWhere(filterClause: "\"a\" = $1 AND \"b\" = $2", filterParams: [.integer(1), .integer(2)], cursor: cursor, dialect: .postgresql, quote: quote)
        #expect(out.clause == "(\"a\" = $1 AND \"b\" = $2) AND \"id\" > $3")
        #expect(out.params == [.integer(1), .integer(2), .integer(10)])
    }

    @Test func combineWhereMysqlUsesQuestionMarkAndDescOperator() {
        let cursor = KeysetCursor(column: "id", value: .integer(10), ascending: false)
        let out = KeysetPaginator.combineWhere(filterClause: "`a` = ?", filterParams: [.integer(1)], cursor: cursor, dialect: .mysql, quote: { "`\($0)`" })
        #expect(out.clause == "(`a` = ?) AND `id` < ?")
        #expect(out.params == [.integer(1), .integer(10)])
    }

    @Test func combineWhereWithoutFilterYieldsBareFragment() {
        let cursor = KeysetCursor(column: "id", value: .integer(3), ascending: true)
        let out = KeysetPaginator.combineWhere(filterClause: nil, filterParams: [], cursor: cursor, dialect: .sqlite, quote: quote)
        #expect(out.clause == "\"id\" > ?")
        #expect(out.params == [.integer(3)])
    }
}