import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-4a 离线单测：流式 CSV 解析（跨块边界）、JSON 解析、类型推断、列映射、参数化 INSERT 拼装。

@Suite struct CSVStreamParserTests {
    private func parseAll(_ text: String, chunkSize: Int) -> [[String]] {
        let parser = CSVStreamParser()
        var rows: [[String]] = []
        let bytes = Array(text.utf8)
        var start = 0
        while start < bytes.count {
            let end = min(start + chunkSize, bytes.count)
            rows += parser.feed(Data(bytes[start..<end]))
            start = end
        }
        rows += parser.finish()
        return rows
    }

    @Test func basicRows() {
        #expect(parseAll("a,b\n1,2\n3,4", chunkSize: 64) == [["a", "b"], ["1", "2"], ["3", "4"]])
    }

    @Test func quotedFieldsWithCommaNewlineAndEscapedQuote() {
        let text = "\"x,y\",\"line1\nline2\",\"say \"\"hi\"\"\"\n"
        #expect(parseAll(text, chunkSize: 64) == [["x,y", "line1\nline2", "say \"hi\""]])
    }

    @Test func crlfLineEndings() {
        #expect(parseAll("a,b\r\n1,2\r\n", chunkSize: 64) == [["a", "b"], ["1", "2"]])
    }

    @Test func chunkBoundariesSplitQuotesEscapesCRLFAndUTF8() {
        let text = "名,\"a\"\"b\",值\r\n甲,\"跨\n块\",乙\r\n"
        let expected: [[String]] = [["名", "a\"b", "值"], ["甲", "跨\n块", "乙"]]
        for chunk in 1...12 {
            #expect(parseAll(text, chunkSize: chunk) == expected, "chunkSize=\(chunk)")
        }
    }

    @Test func unterminatedQuoteAtEOF() {
        #expect(parseAll("a,\"open", chunkSize: 3) == [["a", "open"]])
    }

    @Test func trailingEmptyLineDropped() {
        #expect(parseAll("a,b\n1,2\n\n", chunkSize: 64) == [["a", "b"], ["1", "2"]])
    }

    @Test func emptyInputProducesNoRows() {
        #expect(parseAll("", chunkSize: 64) == [])
    }

    @Test func singleColumnAndEmptyFields() {
        #expect(parseAll("a\n\nb\n", chunkSize: 2) == [["a"], [""], ["b"]])
    }

    @Test func matchesWholeTextParserAcrossChunkSizes() {
        let text = "id,name,note\n1,\"Smith, John\",\"He said \"\"ok\"\"\"\n2,李四,\"多\n行\"\n3,,plain\n"
        let whole = GridPasteParser.parseCSV(text)
        for chunk in [1, 2, 3, 7, 16, 1024] {
            #expect(parseAll(text, chunkSize: chunk) == whole, "chunkSize=\(chunk)")
        }
    }

    @Test func largeStreamKeepsOnlyCurrentRow() {
        // 1 万行流式喂入：结果完整且解析器不累积历史行。
        let parser = CSVStreamParser()
        var count = 0
        for i in 0..<10_000 {
            count += parser.feed(Data(" \(i),value\(i)\n".utf8)).count
        }
        count += parser.finish().count
        #expect(count == 10_000)
    }
}

@Suite struct ImportTypeInferenceTests {
    @Test func integers() {
        #expect(ImportTypeInference.infer(["1", "-2", " 3 "]) == .integer)
        #expect(ImportTypeInference.infer(["0", "1"]) == .integer)
    }

    @Test func doubles() {
        #expect(ImportTypeInference.infer(["1.5", "-2", "3e2"]) == .double)
    }

    @Test func booleans() {
        #expect(ImportTypeInference.infer(["true", "FALSE"]) == .boolean)
    }

    @Test func mixedFallsBackToText() {
        #expect(ImportTypeInference.infer(["1", "abc"]) == .text)
        #expect(ImportTypeInference.infer(["1.5", "true"]) == .text)
    }

    @Test func emptySamplesAreText() {
        #expect(ImportTypeInference.infer([]) == .text)
        #expect(ImportTypeInference.infer(["", "  "]) == .text)
    }

    @Test func nonFiniteIsNotDouble() {
        #expect(ImportTypeInference.infer(["nan", "inf"]) == .text)
    }

    @Test func sqlTypeClassification() {
        #expect(ImportColumnType.from(sqlType: "INTEGER") == .integer)
        #expect(ImportColumnType.from(sqlType: "bigint(20)") == .integer)
        #expect(ImportColumnType.from(sqlType: "serial") == .integer)
        #expect(ImportColumnType.from(sqlType: "BOOLEAN") == .boolean)
        #expect(ImportColumnType.from(sqlType: "bool") == .boolean)
        #expect(ImportColumnType.from(sqlType: "DOUBLE PRECISION") == .double)
        #expect(ImportColumnType.from(sqlType: "numeric(10,2)") == .double)
        #expect(ImportColumnType.from(sqlType: "float8") == .double)
        #expect(ImportColumnType.from(sqlType: "VARCHAR(255)") == .text)
        #expect(ImportColumnType.from(sqlType: "timestamp") == .text)
        #expect(ImportColumnType.from(sqlType: "interval") == .text)
        #expect(ImportColumnType.from(sqlType: "point") == .text)
    }

    @Test func createTableTypes() {
        #expect(ImportColumnType.integer.createTableType == "INTEGER")
        #expect(ImportColumnType.double.createTableType == "REAL")
        #expect(ImportColumnType.boolean.createTableType == "BOOLEAN")
        #expect(ImportColumnType.text.createTableType == "TEXT")
    }
}

@Suite struct ImportValueConverterTests {
    @Test func nullAndMissingBindNull() throws {
        #expect(try ImportValueConverter.databaseValue(.null, as: .integer, column: "c", emptyAsNull: true) == .null)
        #expect(try ImportValueConverter.databaseValue(.missing, as: .text, column: "c", emptyAsNull: false) == .null)
    }

    @Test func emptyStringHonorsOption() throws {
        #expect(try ImportValueConverter.databaseValue(.text(""), as: .integer, column: "c", emptyAsNull: true) == .null)
        #expect(try ImportValueConverter.databaseValue(.text("  "), as: .text, column: "c", emptyAsNull: false) == .string("  "))
    }

    @Test func typedConversion() throws {
        #expect(try ImportValueConverter.databaseValue(.text(" 42 "), as: .integer, column: "c", emptyAsNull: true) == .integer(42))
        #expect(try ImportValueConverter.databaseValue(.text("1.25"), as: .double, column: "c", emptyAsNull: true) == .double(1.25))
        #expect(try ImportValueConverter.databaseValue(.text("yes"), as: .boolean, column: "c", emptyAsNull: true) == .bool(true))
        #expect(try ImportValueConverter.databaseValue(.text("0"), as: .boolean, column: "c", emptyAsNull: true) == .bool(false))
        #expect(try ImportValueConverter.databaseValue(.text("raw"), as: .text, column: "c", emptyAsNull: true) == .string("raw"))
    }

    @Test func conversionFailureThrows() {
        #expect(throws: ImportError.conversionFailed(column: "c", value: "abc")) {
            try ImportValueConverter.databaseValue(.text("abc"), as: .integer, column: "c", emptyAsNull: true)
        }
        #expect(throws: ImportError.conversionFailed(column: "c", value: "nan")) {
            try ImportValueConverter.databaseValue(.text("nan"), as: .double, column: "c", emptyAsNull: true)
        }
        #expect(throws: ImportError.conversionFailed(column: "c", value: "maybe")) {
            try ImportValueConverter.databaseValue(.text("maybe"), as: .boolean, column: "c", emptyAsNull: true)
        }
    }
}

@Suite struct ImportMappingTests {
    @Test func autoMapAlignsCaseInsensitivelyAndSkipsUnmatched() {
        let mappings = ImportMappingBuilder.autoMap(
            sourceColumns: ["ID", "Name", "extra"],
            targetColumns: ["id", "name"],
            samples: [["1", "a", "x"], ["2", "b", "y"]]
        )
        #expect(mappings.map(\.targetColumn) == ["id", "name", nil])
        #expect(mappings[0].inferredType == .integer)
        #expect(mappings[1].inferredType == .text)
    }

    @Test func validateRejectsDuplicateTarget() {
        let mappings = [
            ImportColumnMapping(sourceColumn: "a", targetColumn: "id", inferredType: .text),
            ImportColumnMapping(sourceColumn: "b", targetColumn: "ID", inferredType: .text),
        ]
        #expect(throws: ImportError.duplicateTargetColumn("ID")) {
            try ImportMappingBuilder.validate(mappings)
        }
    }

    @Test func validateRejectsNoMappedColumns() {
        let mappings = [ImportColumnMapping(sourceColumn: "a", targetColumn: nil, inferredType: .text)]
        #expect(throws: ImportError.noMappedColumns) {
            try ImportMappingBuilder.validate(mappings)
        }
    }

    @Test func validateAcceptsWellFormed() throws {
        let mappings = [
            ImportColumnMapping(sourceColumn: "a", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "b", targetColumn: nil, inferredType: .text),
        ]
        try ImportMappingBuilder.validate(mappings)
    }

    @Test func newTableDraftUsesInferredTypesAndSkipsUnmapped() {
        let mappings = [
            ImportColumnMapping(sourceColumn: "a", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "b", targetColumn: "score", inferredType: .double),
            ImportColumnMapping(sourceColumn: "c", targetColumn: nil, inferredType: .text),
        ]
        let draft = ImportMappingBuilder.newTableDraft(name: "imp", mappings: mappings)
        #expect(draft.name == "imp")
        #expect(draft.columns.map(\.name) == ["id", "score"])
        #expect(draft.columns.map(\.dataType) == ["INTEGER", "REAL"])
        #expect(draft.columns.allSatisfy { $0.isNullable })
        #expect(draft.primaryKey.isEmpty)
    }
}

@Suite struct ImportSQLBuilderTests {
    private func table(_ schema: String? = nil) -> DatabaseObject {
        DatabaseObject(kind: .table, name: "orders", schema: schema)
    }

    @Test func sqliteAndMySQLUseQuestionMarks() {
        for type in [DatabaseType.sqlite, .mysql] {
            let sql = ImportSQLBuilder.insertStatement(table: table(), columns: ["id", "name"], rowCount: 2, type: type)
            #expect(sql.hasSuffix("VALUES (?, ?), (?, ?)"))
            #expect(sql.contains("INSERT INTO"))
        }
    }

    @Test func postgresUsesNumberedPlaceholders() {
        let sql = ImportSQLBuilder.insertStatement(table: table("public"), columns: ["id", "name"], rowCount: 2, type: .postgresql)
        #expect(sql.contains("\"public\".\"orders\""))
        #expect(sql.hasSuffix("VALUES ($1, $2), ($3, $4)"))
    }

    @Test func identifierQuotingEscaped() {
        let sql = ImportSQLBuilder.insertStatement(table: table(), columns: ["a\"b"], rowCount: 1, type: .sqlite)
        #expect(sql.contains("\"a\"\"b\""))
    }
}

@Suite struct JSONImportParserTests {
    @Test func arrayOfObjectsUnionsKeys() throws {
        let result = try JSONImportParser.parse("[{\"id\":1,\"name\":\"a\"},{\"id\":2,\"note\":\"x\"}]")
        #expect(result.columns == ["id", "name", "note"])
        #expect(result.rows[0] == [.text("1"), .text("a"), .missing])
        #expect(result.rows[1] == [.text("2"), .missing, .text("x")])
    }

    @Test func nullBooleanAndNested() throws {
        let result = try JSONImportParser.parse("[{\"a\":null,\"b\":true,\"c\":0,\"d\":{\"k\":1}}]")
        #expect(result.rows[0][0] == .null)
        #expect(result.rows[0][1] == .text("true"))
        #expect(result.rows[0][2] == .text("0"))
        #expect(result.rows[0][3] == .text("{\"k\":1}"))
    }

    @Test func singleObject() throws {
        let result = try JSONImportParser.parse("{\"id\":7}")
        #expect(result.columns == ["id"])
        #expect(result.rows == [[.text("7")]])
    }

    @Test func ndjson() throws {
        let result = try JSONImportParser.parse("{\"id\":1}\n{\"id\":2,\"x\":\"y\"}\n")
        #expect(result.columns == ["id", "x"])
        #expect(result.rows.count == 2)
        #expect(result.rows[1] == [.text("2"), .text("y")])
    }

    @Test func arrayOfArraysUsesPositionalColumns() throws {
        let result = try JSONImportParser.parse("[[1,\"a\"],[2]]")
        #expect(result.columns == ["Column 1", "Column 2"])
        #expect(result.rows[1] == [.text("2"), .missing])
    }

    @Test func invalidJSONThrows() {
        #expect(throws: ImportError.self) { try JSONImportParser.parse("not json at all") }
        #expect(throws: ImportError.emptyFile) { try JSONImportParser.parse("   ") }
    }
}

@Suite struct ImportFileFormatTests {
    @Test func detectByExtension() {
        #expect(ImportFileFormat.detect(fileName: "a.csv", head: "") == .csv)
        #expect(ImportFileFormat.detect(fileName: "a.JSON", head: "") == .json)
        #expect(ImportFileFormat.detect(fileName: "a.ndjson", head: "") == .json)
    }

    @Test func detectByContentSniff() {
        #expect(ImportFileFormat.detect(fileName: "a.dat", head: "  [{}]") == .json)
        #expect(ImportFileFormat.detect(fileName: "a.dat", head: "a,b\n") == .csv)
    }
}