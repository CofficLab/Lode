import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-7 网格查找核心：当前页匹配、服务端 LIKE 子句（方言占位符/转义/二进制跳过）。
@Suite
struct GridFindTests {
    private func col(_ name: String, _ type: String) -> TableColumn {
        TableColumn(name: name, dataType: type, isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 0)
    }

    private func displayText(_ value: DatabaseValue) -> String {
        switch value {
        case .integer(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .bool(let v): return String(v)
        case .data(let v): return "<BLOB \(v.count) bytes>"
        case .null: return "NULL"
        }
    }

    @Test func matchesEmptyTermReturnsNone() {
        let rows: [[DatabaseValue]] = [[.string("alice")]]
        #expect(GridFind.matches(columns: ["name"], rows: rows, term: "", text: displayText).isEmpty)
    }

    @Test func matchesCaseInsensitiveRowMajor() {
        let rows: [[DatabaseValue]] = [
            [.integer(1), .string("Alice")],
            [.integer(2), .string("bob")],
            [.integer(3), .string("ALICE again")]
        ]
        let matches = GridFind.matches(columns: ["id", "name"], rows: rows, term: "alice", text: displayText)
        #expect(matches == [GridFind.CellPosition(row: 0, col: 1), GridFind.CellPosition(row: 2, col: 1)])
    }

    @Test func matchesNumericText() {
        let rows: [[DatabaseValue]] = [[.integer(123)], [.integer(456)]]
        let matches = GridFind.matches(columns: ["id"], rows: rows, term: "23", text: displayText)
        #expect(matches == [GridFind.CellPosition(row: 0, col: 0)])
    }

    @Test func matchesRespectsColumnCountBound() {
        // 行比列名多出一列：超出 columns.count 的单元格不参与匹配。
        let rows: [[DatabaseValue]] = [[.string("hit"), .string("hit")]]
        let matches = GridFind.matches(columns: ["a"], rows: rows, term: "hit", text: displayText)
        #expect(matches == [GridFind.CellPosition(row: 0, col: 0)])
    }

    @Test func serverWhereEmptyTermNil() {
        let cols = [col("name", "text")]
        #expect(GridFind.serverWhere(columns: cols, term: "  ", dialect: .sqlite, quote: { "\"\($0)\"" }) == nil)
    }

    @Test func serverWhereAllBinaryNil() {
        let cols = [col("data", "blob"), col("bin", "bytea")]
        #expect(GridFind.serverWhere(columns: cols, term: "x", dialect: .postgresql, quote: { "\"\($0)\"" }) == nil)
    }

    @Test func serverWhereSQLitePositional() {
        let cols = [col("id", "integer"), col("name", "text"), col("data", "blob")]
        let result = GridFind.serverWhere(columns: cols, term: "ann", dialect: .sqlite, quote: { "\"\($0)\"" })
        #expect(result?.clause == "(LOWER(\"id\") LIKE LOWER(?) ESCAPE '!' OR LOWER(\"name\") LIKE LOWER(?) ESCAPE '!')")
        #expect(result?.params == [.string("%ann%"), .string("%ann%")])
    }

    @Test func serverWherePostgresNumberedFromStartIndex() {
        let cols = [col("a", "text"), col("b", "text")]
        let result = GridFind.serverWhere(columns: cols, term: "x", dialect: .postgresql, startIndex: 2, quote: { "\"\($0)\"" })
        #expect(result?.clause == "(LOWER(\"a\") LIKE LOWER($3) ESCAPE '!' OR LOWER(\"b\") LIKE LOWER($4) ESCAPE '!')")
        #expect(result?.params == [.string("%x%"), .string("%x%")])
    }

    @Test func serverWherePostgresCastsNonTextColumns() {
        // PG 的 LOWER 不接受 integer/timestamp，须 CAST AS text；text 列无需 cast。
        let cols = [col("id", "integer"), col("name", "text"), col("created", "timestamp")]
        let result = GridFind.serverWhere(columns: cols, term: "x", dialect: .postgresql, quote: { "\"\($0)\"" })
        #expect(result?.clause == "(LOWER(CAST(\"id\" AS text)) LIKE LOWER($1) ESCAPE '!' OR LOWER(\"name\") LIKE LOWER($2) ESCAPE '!' OR LOWER(CAST(\"created\" AS text)) LIKE LOWER($3) ESCAPE '!')")
    }

    @Test func serverWhereEscapesWildcards() {
        let cols = [col("name", "text")]
        let result = GridFind.serverWhere(columns: cols, term: "a%b_c!d", dialect: .mysql, quote: { "`\($0)`" })
        #expect(result?.params == [.string("%a!%b!_c!!d%")])
        #expect(result?.clause == "(LOWER(`name`) LIKE LOWER(?) ESCAPE '!')")
    }
}

// P2-7 选区摘要核心：计数与数值 sum/avg。
@Suite
struct GridSelectionSummaryTests {
    @Test func emptySelection() {
        let summary = GridSelectionSummary.compute(positions: []) { _ in .null }
        #expect(summary.cellCount == 0)
        #expect(summary.numericCount == 0)
        #expect(summary.average == nil)
        #expect(summary.hasNumeric == false)
    }

    @Test func mixedNumericAndText() {
        let positions: Set<GridFind.CellPosition> = [
            GridFind.CellPosition(row: 0, col: 0),
            GridFind.CellPosition(row: 0, col: 1),
            GridFind.CellPosition(row: 1, col: 0),
            GridFind.CellPosition(row: 1, col: 1)
        ]
        let summary = GridSelectionSummary.compute(positions: positions) { pos in
            switch (pos.row, pos.col) {
            case (0, 0): return .integer(10)
            case (0, 1): return .string("text")
            case (1, 0): return .double(2.5)
            default: return .null
            }
        }
        #expect(summary.cellCount == 4)
        #expect(summary.numericCount == 2)
        #expect(summary.sum == 12.5)
        #expect(summary.average == 6.25)
        #expect(summary.hasNumeric)
    }

    @Test func allNonNumeric() {
        let positions: Set<GridFind.CellPosition> = [GridFind.CellPosition(row: 0, col: 0)]
        let summary = GridSelectionSummary.compute(positions: positions) { _ in .string("abc") }
        #expect(summary.cellCount == 1)
        #expect(summary.numericCount == 0)
        #expect(summary.average == nil)
    }
}