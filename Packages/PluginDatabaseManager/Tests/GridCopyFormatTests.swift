import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-4 复制序列化纯函数验收：
// - JSON：类型保真（null/bool/数值/BLOB hex），可被 JSONSerialization 往返；
// - CSV：RFC 4180 引号规则，NULL → 空字段，BLOB → 0x hex；
// - Markdown：管道转义、换行 <br>、NULL/BLOB 占位文本；
// - INSERT/UPDATE：方言引号、sqlLiteral 转义、预限定表名不二次引号化；
// - UPDATE 无行键/键缺失/全键列时拒绝生成；IN 列表去重跳 NULL。

struct GridCopyFormatTests {
    // MARK: - JSON

    @Test func jsonRoundTripPreservesTypes() throws {
        let columns = ["id", "name", "ok", "ratio", "note", "blob"]
        let row: [DatabaseValue] = [
            .integer(1), .string("a\"b"), .bool(true), .double(1.5), .null, .data(Data([0x01, 0xAB]))
        ]
        let text = GridCopyFormat.rowJSON(columns: columns, row: row)
        let data = try #require(text.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? Int == 1)
        #expect(object["name"] as? String == "a\"b")
        #expect(object["ok"] as? Bool == true)
        #expect(object["ratio"] as? Double == 1.5)
        #expect(object["note"] is NSNull)
        #expect(object["blob"] as? String == "0x01ab")
    }

    @Test func jsonSkipsMissingRowValues() throws {
        let text = GridCopyFormat.rowJSON(columns: ["a", "b"], row: [.integer(1)])
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object.count == 1)
        #expect(object["a"] as? Int == 1)
    }

    // MARK: - CSV

    @Test func csvQuotesSpecialCharacters() {
        let columns = ["a", "b", "c", "d"]
        let row: [DatabaseValue] = [.string("x,y"), .string("say \"hi\""), .string("l1\nl2"), .string("plain")]
        #expect(GridCopyFormat.rowCSV(columns: columns, row: row) == "\"x,y\",\"say \"\"hi\"\"\",\"l1\nl2\",plain")
    }

    @Test func csvNullIsEmptyAndBlobIsHex() {
        let columns = ["a", "b"]
        let row: [DatabaseValue] = [.null, .data(Data([0xDE, 0xAD]))]
        #expect(GridCopyFormat.rowCSV(columns: columns, row: row) == ",0xdead")
    }

    @Test func csvWithHeadersUsesCRLF() {
        let text = GridCopyFormat.csvWithHeaders(columns: ["id", "name"], rows: [[.integer(1), .string("a")], [.integer(2), .string("b")]])
        #expect(text == "id,name\r\n1,a\r\n2,b")
    }

    @Test func csvRoundTripsThroughPasteParser() throws {
        let columns = ["id", "name"]
        let rows: [[DatabaseValue]] = [[.integer(1), .string("a,b")], [.integer(2), .string("say \"hi\"")]]
        let text = GridCopyFormat.csvWithHeaders(columns: columns, rows: rows)
        let parsed = try #require(GridPasteParser.parse(text, columns: columns))
        #expect(parsed == [[.text("1"), .text("a,b")], [.text("2"), .text("say \"hi\"")]])
    }

    // MARK: - Markdown

    @Test func markdownTableStructureAndEscaping() {
        let columns = ["id", "note"]
        let rows: [[DatabaseValue]] = [[.integer(1), .string("a|b\nc")], [.integer(2), .null]]
        let text = GridCopyFormat.markdownTable(columns: columns, rows: rows)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "| id | note |")
        #expect(lines[1] == "| --- | --- |")
        #expect(lines[2] == "| 1 | a\\|b<br>c |")
        #expect(lines[3] == "| 2 | NULL |")
    }

    @Test func markdownBlobPlaceholder() {
        let text = GridCopyFormat.markdownTable(columns: ["b"], rows: [[.data(Data([0x00, 0x01, 0x02]))]])
        #expect(text.contains("<BLOB 3 bytes>"))
    }

    // MARK: - INSERT

    @Test func insertSQLiteQuotesAndEscapes() {
        let sql = GridCopyFormat.insertSQL(
            tableExpr: "\"t\"", columns: ["id", "name"], row: [.integer(1), .string("O'Brien")], dialect: .sqlite)
        #expect(sql == "INSERT INTO \"t\" (\"id\", \"name\") VALUES (1, 'O''Brien');")
    }

    @Test func insertMySQLPreQualifiedTableNotRequoted() {
        let sql = GridCopyFormat.insertSQL(
            tableExpr: "`db`.`t`", columns: ["flag", "blob"], row: [.bool(true), .data(Data([0xAB]))], dialect: .mysql)
        #expect(sql == "INSERT INTO `db`.`t` (`flag`, `blob`) VALUES (TRUE, X'ab');")
    }

    @Test func insertPostgresSchemaQualified() {
        let sql = GridCopyFormat.insertSQL(
            tableExpr: "\"public\".\"t\"", columns: ["payload"], row: [.data(Data([0x01]))], dialect: .postgresql)
        #expect(sql == "INSERT INTO \"public\".\"t\" (\"payload\") VALUES ('\\x01');")
    }

    @Test func insertMissingValueBecomesNull() {
        let sql = GridCopyFormat.insertSQL(tableExpr: "\"t\"", columns: ["a", "b"], row: [.integer(1)], dialect: .sqlite)
        #expect(sql == "INSERT INTO \"t\" (\"a\", \"b\") VALUES (1, NULL);")
    }

    @Test func insertEscapesQuoteInColumnName() {
        let sql = GridCopyFormat.insertSQL(tableExpr: "\"t\"", columns: ["we\"ird"], row: [.integer(1)], dialect: .sqlite)
        #expect(sql.contains("\"we\"\"ird\""))
    }

    // MARK: - UPDATE

    @Test func updateSetsNonKeysAndWhereKeys() {
        let sql = GridCopyFormat.updateSQL(
            tableExpr: "\"t\"", columns: ["id", "name", "age"], row: [.integer(1), .string("x"), .integer(2)],
            keyColumns: ["id"], dialect: .sqlite)
        #expect(sql == "UPDATE \"t\" SET \"name\" = 'x', \"age\" = 2 WHERE \"id\" = 1;")
    }

    @Test func updateCompositeKey() {
        let sql = GridCopyFormat.updateSQL(
            tableExpr: "`t`", columns: ["a", "b", "v"], row: [.integer(1), .integer(2), .string("z")],
            keyColumns: ["a", "b"], dialect: .mysql)
        #expect(sql == "UPDATE `t` SET `v` = 'z' WHERE `a` = 1 AND `b` = 2;")
    }

    @Test func updateRefusesUnsafeShapes() {
        let columns = ["id", "name"]
        let row: [DatabaseValue] = [.integer(1), .string("x")]
        #expect(GridCopyFormat.updateSQL(tableExpr: "\"t\"", columns: columns, row: row, keyColumns: [], dialect: .sqlite) == nil)
        #expect(GridCopyFormat.updateSQL(tableExpr: "\"t\"", columns: columns, row: row, keyColumns: ["missing"], dialect: .sqlite) == nil)
        #expect(GridCopyFormat.updateSQL(tableExpr: "\"t\"", columns: ["id"], row: [.integer(1)], keyColumns: ["id"], dialect: .sqlite) == nil)
    }

    // MARK: - IN list

    @Test func inListDedupsSkipsNullPreservesOrder() {
        let rows: [[DatabaseValue]] = [[.integer(1)], [.integer(2)], [.integer(1)], [.null], [.integer(3)]]
        let text = GridCopyFormat.inList(column: "id", columns: ["id"], rows: rows, dialect: .sqlite)
        #expect(text == "(1, 2, 3)")
    }

    @Test func inListQuotesStrings() {
        let rows: [[DatabaseValue]] = [[.string("a")], [.string("O'Brien")], [.string("a")]]
        let text = GridCopyFormat.inList(column: "name", columns: ["name"], rows: rows, dialect: .postgresql)
        #expect(text == "('a', 'O''Brien')")
    }

    @Test func inListNilWhenEmptyOrMissingColumn() {
        #expect(GridCopyFormat.inList(column: "id", columns: ["id"], rows: [[.null]], dialect: .sqlite) == nil)
        #expect(GridCopyFormat.inList(column: "id", columns: ["id"], rows: [], dialect: .sqlite) == nil)
        #expect(GridCopyFormat.inList(column: "nope", columns: ["id"], rows: [[.integer(1)]], dialect: .sqlite) == nil)
    }
}