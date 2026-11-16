import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-5a 离线单测：四格式流式写入器（header/row/footer 片段拼装）+ 与导入解析器往返等价 +
// SQL 导出经真实 SQLite 执行回读比对 + 预设 Codable 往返。

private func exText(_ format: ExportFormat, columns: [String], rows: [[DatabaseValue]], tableExpr: String = "\"t\"", dialect: DatabaseType = .sqlite) -> String {
    var text = DataExportWriter.header(format: format, columns: columns) ?? ""
    for (index, row) in rows.enumerated() {
        text += DataExportWriter.row(format: format, columns: columns, row: row, tableExpr: tableExpr, dialect: dialect, isFirst: index == 0)
    }
    text += DataExportWriter.footer(format: format) ?? ""
    return text
}

@Suite(.serialized)
struct DataExportTests {
    private let columns = ["id", "name", "score", "flag", "payload"]
    private var sampleRows: [[DatabaseValue]] {
        [
            [.integer(1), .string("a,b"), .double(1.5), .bool(true), .null],
            [.integer(2), .string("say \"hi\"\nnext"), .double(-2.25), .bool(false), .data(Data([0x01, 0xAB]))],
            [.integer(3), .string("中文"), .null, .null, .string("")],
        ]
    }

    // MARK: - CSV

    @Test func csvRoundTripsThroughStreamParser() throws {
        let text = exText(.csv, columns: columns, rows: sampleRows)
        let parser = CSVStreamParser()
        var parsed = parser.feed(Data(text.utf8))
        parsed += parser.finish()
        #expect(parsed.count == 4)
        #expect(parsed[0] == columns)
        #expect(parsed[1] == ["1", "a,b", "1.5", "true", ""])
        #expect(parsed[2] == ["2", "say \"hi\"\nnext", "-2.25", "false", "0x01ab"])
        #expect(parsed[3] == ["3", "中文", "", "", ""])
        #expect(parsed == GridPasteParser.parseCSV(text))
    }

    @Test func csvHeaderQuotesSpecialColumnNames() {
        let header = DataExportWriter.header(format: .csv, columns: ["a,b", "c\"d", "plain"])
        #expect(header == "\"a,b\",\"c\"\"d\",plain\r\n")
    }

    @Test func csvEmptyRowsIsHeaderOnly() {
        let text = exText(.csv, columns: ["id"], rows: [])
        #expect(text == "id\r\n")
    }

    // MARK: - JSON

    @Test func jsonRoundTripsThroughImportParser() throws {
        let text = exText(.json, columns: columns, rows: sampleRows)
        let parsed = try JSONImportParser.parse(text)
        #expect(parsed.columns == columns.sorted())
        #expect(parsed.rows.count == 3)
        let byColumn = Dictionary(uniqueKeysWithValues: zip(parsed.columns, parsed.rows[0]))
        #expect(byColumn["id"] == .text("1"))
        #expect(byColumn["name"] == .text("a,b"))
        #expect(byColumn["score"] == .text("1.5"))
        #expect(byColumn["flag"] == .text("true"))
        #expect(byColumn["payload"] == .null)
        let row2 = Dictionary(uniqueKeysWithValues: zip(parsed.columns, parsed.rows[1]))
        #expect(row2["flag"] == .text("false"))
        #expect(row2["payload"] == .text("0x01ab"))
        let row3 = Dictionary(uniqueKeysWithValues: zip(parsed.columns, parsed.rows[2]))
        #expect(row3["score"] == .null)
        #expect(row3["payload"] == .text(""))
    }

    @Test func jsonSingleRowHasNoTrailingComma() throws {
        let text = exText(.json, columns: ["id"], rows: [[.integer(7)]])
        #expect(text == "[\n{\"id\":7}\n]\n")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        #expect((object as? [Any])?.count == 1)
    }

    @Test func jsonEmptyRowsIsValidEmptyArray() throws {
        let text = exText(.json, columns: ["id"], rows: [])
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        #expect((object as? [Any])?.isEmpty == true)
    }

    // MARK: - SQL INSERT

    @Test func sqlInsertUsesDialectQuotingAndEscaping() {
        let row: [DatabaseValue] = [.integer(1), .string("O'Brien")]
        let mysql = DataExportWriter.row(format: .sqlInsert, columns: ["id", "name"], row: row, tableExpr: "`db`.`t`", dialect: .mysql, isFirst: true)
        #expect(mysql == "INSERT INTO `db`.`t` (`id`, `name`) VALUES (1, 'O''Brien');\n")
        let pg = DataExportWriter.row(format: .sqlInsert, columns: ["id", "name"], row: row, tableExpr: "\"public\".\"t\"", dialect: .postgresql, isFirst: true)
        #expect(pg == "INSERT INTO \"public\".\"t\" (\"id\", \"name\") VALUES (1, 'O''Brien');\n")
    }

    @Test func sqlExportExecutesAndReadsBackInSQLite() async throws {
        let path = NSTemporaryDirectory() + "lode-ex-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let conn = try SQLiteConnection(path: path)
        defer { Task { await conn.close() } }
        _ = try await conn.execute("CREATE TABLE ex_t (id INTEGER, name TEXT, score REAL, flag BOOLEAN, payload BLOB)", params: nil)
        let text = exText(.sqlInsert, columns: columns, rows: sampleRows, tableExpr: "\"ex_t\"", dialect: .sqlite)
        // 字面量内含换行，按语句解析器切分而非裸换行。
        for statement in SQLStatementParser.split(text) {
            _ = try await conn.execute(statement, params: nil)
        }
        let result = try await conn.query("SELECT id, name, score, flag, payload FROM ex_t ORDER BY id", params: nil)
        #expect(result.rows.count == 3)
        #expect(result.rows[0][0] == .integer(1))
        #expect(result.rows[0][1] == .string("a,b"))
        #expect(result.rows[0][4] == .null)
        #expect(result.rows[1][1] == .string("say \"hi\"\nnext"))
        #expect(result.rows[2][1] == .string("中文"))
        #expect(result.rows[2][2] == .null)
    }

    @Test func sqlEmptyRowsProducesNothing() {
        #expect(exText(.sqlInsert, columns: ["id"], rows: []) == "")
    }

    // MARK: - Markdown

    @Test func markdownEscapesPipesAndNewlines() {
        let header = DataExportWriter.header(format: .markdown, columns: ["a|b", "c"])
        #expect(header == "| a\\|b | c |\n| --- | --- |\n")
        let row = DataExportWriter.row(format: .markdown, columns: ["a|b", "c"], row: [.string("x|y\nz"), .null], tableExpr: "", dialect: .sqlite, isFirst: true)
        #expect(row == "| x\\|y<br>z | NULL |\n")
    }

    @Test func markdownStreamingRowsMatchWholeTable() {
        let whole = GridCopyFormat.markdownTable(columns: columns, rows: sampleRows)
        let streamed = exText(.markdown, columns: columns, rows: sampleRows).trimmingCharacters(in: .newlines)
        #expect(streamed == whole)
    }

    @Test func markdownBlobShowsPlaceholder() {
        let row = DataExportWriter.row(format: .markdown, columns: ["payload"], row: [.data(Data([0x00, 0x01, 0x02]))], tableExpr: "", dialect: .sqlite, isFirst: true)
        #expect(row == "| <BLOB 3 bytes> |\n")
    }

    // MARK: - 预设与格式

    @Test func presetCodableRoundTrip() throws {
        let presets = [
            ExportPreset(name: "Full CSV", format: .csv, range: .allRows),
            ExportPreset(name: "Page JSON", format: .json, range: .currentPage),
            ExportPreset(name: "Filtered SQL", format: .sqlInsert, range: .filteredRows),
        ]
        let data = try JSONEncoder().encode(presets)
        let decoded = try JSONDecoder().decode([ExportPreset].self, from: data)
        #expect(decoded == presets)
    }

    @Test func fileExtensions() {
        #expect(ExportFormat.csv.fileExtension == "csv")
        #expect(ExportFormat.json.fileExtension == "json")
        #expect(ExportFormat.sqlInsert.fileExtension == "sql")
        #expect(ExportFormat.markdown.fileExtension == "md")
    }
}