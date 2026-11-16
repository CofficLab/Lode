import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-3 外键支持纯逻辑单测：
// 查找/选值资格/源值提取/定位过滤（各方言转义）/搜索 SQL（CAST、占位符、ESCAPE）/候选项预览。

@Suite
struct ForeignKeySupportTests {
    private let singleFK = ForeignKey(
        name: "fk_parent",
        columns: ["parent_id"],
        referencesTable: "parents",
        referencesColumns: ["id"]
    )
    private let compositeFK = ForeignKey(
        name: "fk_pair",
        columns: ["a_id", "b_id"],
        referencesTable: "pairs",
        referencesColumns: ["a", "b"]
    )

    private func schema(_ fks: [ForeignKey]) -> TableSchema {
        TableSchema(
            table: DatabaseObject(kind: .table, name: "children"),
            columns: [],
            foreignKeys: fks
        )
    }

    private func col(_ name: String, _ type: String) -> TableColumn {
        TableColumn(name: name, dataType: type, isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 0)
    }

    // MARK: - 查找与资格

    @Test func foreignKeyLookup() {
        let s = schema([singleFK, compositeFK])
        #expect(ForeignKeySupport.foreignKey(for: "parent_id", in: s) == singleFK)
        #expect(ForeignKeySupport.foreignKey(for: "a_id", in: s) == compositeFK)
        #expect(ForeignKeySupport.foreignKey(for: "b_id", in: s) == compositeFK)
        #expect(ForeignKeySupport.foreignKey(for: "missing", in: s) == nil)
        #expect(ForeignKeySupport.foreignKey(for: "parent_id", in: schema([])) == nil)
    }

    @Test func canPickRules() {
        #expect(ForeignKeySupport.canPick(singleFK))
        #expect(!ForeignKeySupport.canPick(compositeFK))
        let emptyRef = ForeignKey(name: "x", columns: ["c"], referencesTable: "", referencesColumns: ["id"])
        #expect(!ForeignKeySupport.canPick(emptyRef))
    }

    @Test func sourceValuesFollowForeignKeyOrder() {
        let columns = ["id", "b_id", "a_id"]
        let row: [DatabaseValue] = [.integer(1), .integer(20), .integer(10)]
        #expect(ForeignKeySupport.sourceValues(compositeFK, rowValues: row, columns: columns) == [.integer(10), .integer(20)])
        #expect(ForeignKeySupport.sourceValues(singleFK, rowValues: row, columns: columns) == nil)
        #expect(ForeignKeySupport.sourceValues(singleFK, rowValues: [.integer(5)], columns: ["parent_id"]) == [.integer(5)])
    }

    @Test func canLocateRejectsNullBlobAndMismatch() {
        #expect(ForeignKeySupport.canLocate(singleFK, values: [.integer(7)]))
        #expect(ForeignKeySupport.canLocate(singleFK, values: [.string("x")]))
        #expect(!ForeignKeySupport.canLocate(singleFK, values: [.null]))
        #expect(!ForeignKeySupport.canLocate(singleFK, values: [.data(Data([0x01]))]))
        #expect(!ForeignKeySupport.canLocate(singleFK, values: []))
        #expect(!ForeignKeySupport.canLocate(singleFK, values: [.integer(1), .integer(2)]))
        #expect(ForeignKeySupport.canLocate(compositeFK, values: [.integer(1), .integer(2)]))
        #expect(!ForeignKeySupport.canLocate(compositeFK, values: [.integer(1), .null]))
    }

    // MARK: - 定位过滤

    @Test func locateFilterSQLite() throws {
        let filter = try #require(ForeignKeySupport.locateFilter(singleFK, values: [.integer(7)], dialect: .sqlite))
        #expect(filter.useRawWhere)
        #expect(filter.rawWhere == "\"id\" = 7")
        #expect(filter.isActive)
        let whereClause = try #require(filter.buildWhere(dialect: .sqlite))
        #expect(whereClause.clause == "\"id\" = 7")
        #expect(whereClause.params.isEmpty)
    }

    @Test func locateFilterEscapesStringLiteral() throws {
        let fk = ForeignKey(name: "fk_name", columns: ["name"], referencesTable: "people", referencesColumns: ["name"])
        let filter = try #require(ForeignKeySupport.locateFilter(fk, values: [.string("O'Brien")], dialect: .sqlite))
        #expect(filter.rawWhere == "\"name\" = 'O''Brien'")
    }

    @Test func locateFilterCompositePerDialect() throws {
        let mysql = try #require(ForeignKeySupport.locateFilter(compositeFK, values: [.integer(1), .integer(2)], dialect: .mysql))
        #expect(mysql.rawWhere == "`a` = 1 AND `b` = 2")
        let pg = try #require(ForeignKeySupport.locateFilter(compositeFK, values: [.integer(1), .integer(2)], dialect: .postgresql))
        #expect(pg.rawWhere == "\"a\" = 1 AND \"b\" = 2")
    }

    @Test func locateFilterRejectsUnlocatableValues() {
        #expect(ForeignKeySupport.locateFilter(singleFK, values: [.null], dialect: .sqlite) == nil)
        #expect(ForeignKeySupport.locateFilter(singleFK, values: [.data(Data())], dialect: .mysql) == nil)
        #expect(ForeignKeySupport.locateFilter(compositeFK, values: [.integer(1)], dialect: .postgresql) == nil)
    }

    // MARK: - 搜索 SQL

    @Test func referenceSearchEmptySearch() throws {
        let query = try #require(ForeignKeySupport.referenceSearchSQL(singleFK, dialect: .sqlite, search: ""))
        #expect(query.sql == "SELECT * FROM \"parents\" ORDER BY \"id\" ASC LIMIT 50")
        #expect(query.params.isEmpty)
        let whitespace = try #require(ForeignKeySupport.referenceSearchSQL(singleFK, dialect: .sqlite, search: "   "))
        #expect(whitespace.params.isEmpty)
    }

    @Test func referenceSearchSkipsBinaryColumns() throws {
        let columns = [col("id", "INTEGER"), col("name", "TEXT"), col("payload", "BLOB")]
        let query = try #require(ForeignKeySupport.referenceSearchSQL(singleFK, dialect: .sqlite, search: "alp", searchColumns: columns))
        #expect(query.sql == "SELECT * FROM \"parents\" WHERE LOWER(\"id\") LIKE LOWER(?) ESCAPE '!' OR LOWER(\"name\") LIKE LOWER(?) ESCAPE '!' ORDER BY \"id\" ASC LIMIT 50")
        #expect(query.params == [.string("%alp%"), .string("%alp%")])
    }

    @Test func referenceSearchFallsBackToKeyColumn() throws {
        let query = try #require(ForeignKeySupport.referenceSearchSQL(singleFK, dialect: .sqlite, search: "7", searchColumns: []))
        #expect(query.sql == "SELECT * FROM \"parents\" WHERE LOWER(\"id\") LIKE LOWER(?) ESCAPE '!' ORDER BY \"id\" ASC LIMIT 50")
        #expect(query.params == [.string("%7%")])
    }

    @Test func referenceSearchMySQLCast() throws {
        let query = try #require(ForeignKeySupport.referenceSearchSQL(singleFK, dialect: .mysql, search: "x", searchColumns: [col("id", "INT")]))
        #expect(query.sql == "SELECT * FROM `parents` WHERE LOWER(CAST(`id` AS CHAR)) LIKE LOWER(?) ESCAPE '!' ORDER BY `id` ASC LIMIT 50")
    }

    @Test func referenceSearchPGPlaceholders() throws {
        let columns = [col("id", "int4"), col("name", "text")]
        let query = try #require(ForeignKeySupport.referenceSearchSQL(singleFK, dialect: .postgresql, search: "x", searchColumns: columns))
        #expect(query.sql == "SELECT * FROM \"parents\" WHERE LOWER(CAST(\"id\" AS TEXT)) LIKE LOWER($1) ESCAPE '!' OR LOWER(CAST(\"name\" AS TEXT)) LIKE LOWER($2) ESCAPE '!' ORDER BY \"id\" ASC LIMIT 50")
        #expect(query.params == [.string("%x%"), .string("%x%")])
    }

    @Test func referenceSearchEscapesWildcards() throws {
        let query = try #require(ForeignKeySupport.referenceSearchSQL(singleFK, dialect: .sqlite, search: "a%b_c!d"))
        #expect(query.params == [.string("%a!%b!_c!!d%")])
    }

    @Test func referenceSearchRejectsCompositeAndHonorsLimit() throws {
        #expect(ForeignKeySupport.referenceSearchSQL(compositeFK, dialect: .sqlite, search: "") == nil)
        let query = try #require(ForeignKeySupport.referenceSearchSQL(singleFK, dialect: .sqlite, search: "", limit: 10))
        #expect(query.sql.hasSuffix("LIMIT 10"))
    }

    @Test func escapeLikeWildcards() {
        #expect(ForeignKeySupport.escapeLike("a%b_c!d") == "a!%b!_c!!d")
        #expect(ForeignKeySupport.escapeLike("plain") == "plain")
    }

    // MARK: - 候选项

    @Test func optionsExtractKeyAndPreview() {
        let result = QueryResult(
            columns: ["id", "name", "note"],
            rows: [
                [.integer(1), .string("Alpha"), .string("hello")],
                [.integer(2), .string("Beta"), .null]
            ],
            rowsAffected: 0
        )
        let options = ForeignKeySupport.options(from: result, fk: singleFK)
        #expect(options.count == 2)
        #expect(options[0].keyValue == .integer(1))
        #expect(options[0].preview == "name: Alpha · note: hello")
        #expect(options[1].preview == "name: Beta · note: NULL")
    }

    @Test func optionsTruncateLongPreviewValues() {
        let long = String(repeating: "x", count: 60)
        let result = QueryResult(columns: ["id", "name"], rows: [[.integer(1), .string(long)]], rowsAffected: 0)
        let options = ForeignKeySupport.options(from: result, fk: singleFK)
        #expect(options[0].preview == "name: " + String(repeating: "x", count: 40) + "…")
    }

    @Test func optionsLimitPreviewToThreeColumns() {
        let result = QueryResult(
            columns: ["id", "a", "b", "c", "d"],
            rows: [[.integer(1), .string("1"), .string("2"), .string("3"), .string("4")]],
            rowsAffected: 0
        )
        let options = ForeignKeySupport.options(from: result, fk: singleFK)
        #expect(options[0].preview == "a: 1 · b: 2 · c: 3")
    }

    @Test func optionsRequireKeyColumnPresent() {
        let result = QueryResult(columns: ["name"], rows: [[.string("Alpha")]], rowsAffected: 0)
        #expect(ForeignKeySupport.options(from: result, fk: singleFK).isEmpty)
        #expect(ForeignKeySupport.options(from: result, fk: compositeFK).isEmpty)
    }
}