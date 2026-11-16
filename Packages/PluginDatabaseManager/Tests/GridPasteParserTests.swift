import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-4 粘贴解析纯函数验收：
// - CSV：位置映射 / 表头按名乱序映射（大小写不敏感）/ RFC 4180 引号内逗号、
//   翻倍引号、换行 / CRLF 与 CR / 短行尾部 .unset / 空字段 .text("")；
// - JSON：对象数组按列名（null → .null，缺键 → .unset）、单对象、数组的数组、
//   bool/数值转文本；非法 JSON / 空数组 / 标量 → nil；
// - 三态语义：.unset 保留数据库默认值，.null 显式置空。

struct GridPasteParserTests {
    private let columns = ["id", "name"]

    // MARK: - CSV

    @Test func positionalCSV() throws {
        let parsed = try #require(GridPasteParser.parse("1,Alice\n2,Bob", columns: columns))
        #expect(parsed == [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]])
    }

    @Test func headerReordersByName() throws {
        let parsed = try #require(GridPasteParser.parse("name,id\nAlice,1", columns: columns))
        #expect(parsed == [[.text("1"), .text("Alice")]])
    }

    @Test func headerIsCaseInsensitive() throws {
        let parsed = try #require(GridPasteParser.parse("ID,NAME\n1,x", columns: columns))
        #expect(parsed == [[.text("1"), .text("x")]])
    }

    @Test func quotedFieldsWithCommaQuoteNewline() throws {
        let text = "1,\"a,b\"\n2,\"say \"\"hi\"\"\"\n3,\"l1\nl2\""
        let parsed = try #require(GridPasteParser.parse(text, columns: columns))
        #expect(parsed == [
            [.text("1"), .text("a,b")],
            [.text("2"), .text("say \"hi\"")],
            [.text("3"), .text("l1\nl2")]
        ])
    }

    @Test func crlfAndTrailingNewline() throws {
        let parsed = try #require(GridPasteParser.parse("1,a\r\n2,b\r\n", columns: columns))
        #expect(parsed.count == 2)
    }

    @Test func crOnlyLineEndings() throws {
        let parsed = try #require(GridPasteParser.parse("1,a\r2,b", columns: columns))
        #expect(parsed.count == 2)
    }

    @Test func shortRowLeavesTrailingUnset() throws {
        let parsed = try #require(GridPasteParser.parse("1", columns: columns))
        #expect(parsed == [[.text("1"), .unset]])
    }

    @Test func emptyFieldIsEmptyTextNotNull() throws {
        let parsed = try #require(GridPasteParser.parse("1,\n2,x", columns: columns))
        #expect(parsed[0] == [.text("1"), .text("")])
    }

    @Test func headerOnlyReturnsNil() {
        #expect(GridPasteParser.parse("id,name", columns: columns) == nil)
    }

    @Test func emptyInputReturnsNil() {
        #expect(GridPasteParser.parse("", columns: columns) == nil)
        #expect(GridPasteParser.parse("  \n ", columns: columns) == nil)
        #expect(GridPasteParser.parse("1,a", columns: []) == nil)
    }

    @Test func singleColumnMultiline() throws {
        let parsed = try #require(GridPasteParser.parse("a\nb", columns: ["name"]))
        #expect(parsed == [[.text("a")], [.text("b")]])
    }

    @Test func singleColumnHeaderStillDetected() throws {
        let parsed = try #require(GridPasteParser.parse("name\nx", columns: ["name"]))
        #expect(parsed == [[.text("x")]])
    }

    @Test func parseCSVQuoteOnlyOpensAtFieldStart() {
        #expect(GridPasteParser.parseCSV("a\"b") == [["a\"b"]])
    }

    @Test func parseCSVDropsTrailingBlankLine() {
        #expect(GridPasteParser.parseCSV("1\n\n") == [["1"]])
    }

    @Test func parseCSVRoundTripsCopyFormat() {
        let columns = ["id", "name"]
        let rows: [[DatabaseValue]] = [[.integer(1), .string("a,b")], [.integer(2), .null]]
        let text = GridCopyFormat.csvWithHeaders(columns: columns, rows: rows)
        let raw = GridPasteParser.parseCSV(text)
        #expect(raw == [["id", "name"], ["1", "a,b"], ["2", ""]])
    }

    // MARK: - JSON

    @Test func jsonObjectArrayMapsByName() throws {
        let parsed = try #require(GridPasteParser.parse("[{\"id\":1,\"name\":\"a\"},{\"id\":2}]", columns: columns))
        #expect(parsed == [[.text("1"), .text("a")], [.text("2"), .unset]])
    }

    @Test func jsonNullIsExplicitNull() throws {
        let parsed = try #require(GridPasteParser.parse("[{\"id\":null,\"name\":\"a\"}]", columns: columns))
        #expect(parsed == [[.null, .text("a")]])
    }

    @Test func jsonSingleObjectIsOneRow() throws {
        let parsed = try #require(GridPasteParser.parse("{\"id\":5,\"name\":\"x\"}", columns: columns))
        #expect(parsed == [[.text("5"), .text("x")]])
    }

    @Test func jsonArrayArraysPositional() throws {
        let parsed = try #require(GridPasteParser.parse("[[1,\"a\"],[2]]", columns: columns))
        #expect(parsed == [[.text("1"), .text("a")], [.text("2"), .unset]])
    }

    @Test func jsonBoolAndNumberBecomeText() throws {
        let parsed = try #require(GridPasteParser.parse("[{\"id\":true,\"name\":1.5}]", columns: columns))
        #expect(parsed == [[.text("true"), .text("1.5")]])
    }

    @Test func jsonExtraKeysIgnoredAndKeysCaseSensitive() throws {
        let parsed = try #require(GridPasteParser.parse("[{\"id\":1,\"zzz\":\"q\"},{\"ID\":2}]", columns: columns))
        #expect(parsed == [[.text("1"), .unset], [.unset, .unset]])
    }

    @Test func malformedJSONReturnsNil() {
        #expect(GridPasteParser.parse("[{bad", columns: columns) == nil)
        #expect(GridPasteParser.parse("[]", columns: columns) == nil)
    }

    @Test func bareNumberIsPositionalCSV() throws {
        let parsed = try #require(GridPasteParser.parse("42", columns: columns))
        #expect(parsed == [[.text("42"), .unset]])
    }

    @Test func subsetHeaderMapsByNameLeavesRestUnset() throws {
        let parsed = try #require(GridPasteParser.parse("name\nAlice", columns: columns))
        #expect(parsed == [[.unset, .text("Alice")]])
    }

    @Test func subsetReorderedHeaderWithDataRow() throws {
        let parsed = try #require(GridPasteParser.parse("qty,name,id\n8,eight,7", columns: ["id", "name", "qty", "note"]))
        #expect(parsed == [[.text("7"), .text("eight"), .text("8"), .unset]])
    }

    @Test func jsonIntegerOneAndZeroAreNotBool() throws {
        let parsed = try #require(GridPasteParser.parse("[{\"id\":1,\"name\":0}]", columns: columns))
        #expect(parsed == [[.text("1"), .text("0")]])
    }

    @Test func jsonRoundTripsRowCopy() throws {
        let columns = ["id", "name", "note"]
        let row: [DatabaseValue] = [.integer(7), .string("O'Brien"), .null]
        let text = GridCopyFormat.rowJSON(columns: columns, row: row)
        let parsed = try #require(GridPasteParser.parse(text, columns: columns))
        #expect(parsed == [[.text("7"), .text("O'Brien"), .null]])
    }
}