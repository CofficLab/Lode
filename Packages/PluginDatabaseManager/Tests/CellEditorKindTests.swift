import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-2 编辑器路由层单元测试：
// - 类型名 → 编辑器种类（含修饰符、PG 数组、枚举优先）；
// - MySQL enum('…') 取值解析（'' 与 \' 转义）；
// - 日期/时间文本 ↔ Date 往返（固定 UTC 格式）；
// - JSON 文本校验（对象/数组/标量合法，残缺非法）。
@Suite struct CellEditorKindTests {
    // MARK: - 路由

    @Test func routesNumericAndBooleanFamilies() {
        #expect(cellEditorKind(for: "INTEGER") == .integer)
        #expect(cellEditorKind(for: "bigint(20) unsigned") == .integer)
        #expect(cellEditorKind(for: "tinyint(1)") == .boolean)
        #expect(cellEditorKind(for: "tinyint(4)") == .integer)
        #expect(cellEditorKind(for: "BOOLEAN") == .boolean)
        #expect(cellEditorKind(for: "numeric(10,2)") == .decimal)
        #expect(cellEditorKind(for: "double precision") == .decimal)
    }

    @Test func routesDateAndTimeFamilies() {
        #expect(cellEditorKind(for: "DATE") == .date)
        #expect(cellEditorKind(for: "date") == .date)
        #expect(cellEditorKind(for: "DATETIME") == .dateTime)
        #expect(cellEditorKind(for: "timestamp") == .dateTime)
        #expect(cellEditorKind(for: "timestamptz") == .dateTime)
        #expect(cellEditorKind(for: "timestamp without time zone") == .dateTime)
        #expect(cellEditorKind(for: "timestamp with time zone") == .dateTime)
        #expect(cellEditorKind(for: "TIME") == .time)
        #expect(cellEditorKind(for: "time without time zone") == .time)
        #expect(cellEditorKind(for: "timetz") == .time)
    }

    @Test func routesJSONAndBinaryAndText() {
        #expect(cellEditorKind(for: "json") == .json)
        #expect(cellEditorKind(for: "JSONB") == .json)
        #expect(cellEditorKind(for: "bytea") == .binary)
        #expect(cellEditorKind(for: "varbinary(64)") == .binary)
        #expect(cellEditorKind(for: "varchar(255)") == .text)
        #expect(cellEditorKind(for: "TEXT") == .text)
        #expect(cellEditorKind(for: "geometry") == .text)
    }

    @Test func pgArraysEditTextLiterals() {
        #expect(cellEditorKind(for: "integer[]") == .text)
        #expect(cellEditorKind(for: "text[]") == .text)
        #expect(cellEditorKind(for: "_int4") == .text)
    }

    @Test func enumValuesTakePriority() {
        #expect(cellEditorKind(for: "enum('a','b')", enumValues: ["a", "b"]) == .enumeration(["a", "b"]))
        #expect(cellEditorKind(for: "USER-DEFINED", enumValues: ["happy", "sad"]) == .enumeration(["happy", "sad"]))
        #expect(cellEditorKind(for: "enum('a')", enumValues: []) == .text)
        #expect(cellEditorKind(for: "varchar(8)", enumValues: nil) == .text)
    }

    // MARK: - MySQL enum 解析

    @Test func parsesMySQLEnumValues() {
        #expect(mysqlEnumValues(in: "enum('red','green','blue')") == ["red", "green", "blue"])
        #expect(mysqlEnumValues(in: "ENUM('a','b')") == ["a", "b"])
        #expect(mysqlEnumValues(in: "enum('')") == [""])
    }

    @Test func parsesEscapedQuotesInEnum() {
        #expect(mysqlEnumValues(in: "enum('it''s','ok')") == ["it's", "ok"])
        #expect(mysqlEnumValues(in: "enum('a\\'b','c')") == ["a'b", "c"])
    }

    @Test func nonEnumTypesReturnNil() {
        #expect(mysqlEnumValues(in: "varchar(10)") == nil)
        #expect(mysqlEnumValues(in: "set('a','b')") == nil)
        #expect(mysqlEnumValues(in: "int") == nil)
    }

    // MARK: - 日期往返

    @Test func dateRoundTrip() throws {
        let date = try #require(parseCellDate("2024-03-05", kind: .date))
        #expect(formatCellDate(date, kind: .date) == "2024-03-05")
    }

    @Test func dateTimeRoundTrip() throws {
        let date = try #require(parseCellDate("2024-03-05 14:30:09", kind: .dateTime))
        #expect(formatCellDate(date, kind: .dateTime) == "2024-03-05 14:30:09")
        // ISO 分隔与分钟精度也可解析，提交统一为标准格式。
        let iso = try #require(parseCellDate("2024-03-05T14:30:09", kind: .dateTime))
        #expect(formatCellDate(iso, kind: .dateTime) == "2024-03-05 14:30:09")
        let minute = try #require(parseCellDate("2024-03-05 14:30", kind: .dateTime))
        #expect(formatCellDate(minute, kind: .dateTime) == "2024-03-05 14:30:00")
    }

    @Test func timeRoundTrip() throws {
        let date = try #require(parseCellDate("08:15:42", kind: .time))
        #expect(formatCellDate(date, kind: .time) == "08:15:42")
    }

    @Test func invalidDateTextReturnsNil() {
        #expect(parseCellDate("not a date", kind: .date) == nil)
        #expect(parseCellDate("", kind: .dateTime) == nil)
        #expect(parseCellDate("2024-13-40", kind: .date) == nil)
        #expect(formatCellDate(Date(), kind: .text) == nil)
    }

    @Test func fractionalSecondsKeepMicrosecondPrecision() throws {
        // DateFormatter 的 S 只到毫秒；手动解析必须保留全部 6 位微秒。
        let base = try #require(parseCellDate("2024-03-05 14:30:09", kind: .dateTime))
        let micro = try #require(parseCellDate("2024-03-05 14:30:09.123456", kind: .dateTime))
        #expect(micro == base.addingTimeInterval(0.123456))
        let half = try #require(parseCellDate("2024-03-05 14:30:09.5", kind: .dateTime))
        #expect(half == base.addingTimeInterval(0.5))
        let timeBase = try #require(parseCellDate("08:15:42", kind: .time))
        let timeFrac = try #require(parseCellDate("08:15:42.25", kind: .time))
        #expect(timeFrac == timeBase.addingTimeInterval(0.25))
    }

    @Test func utcZoneSuffixParses() throws {
        // timestamptz 驱动输出附 +00；剥掉后与无后缀文本等价。
        let plain = try #require(parseCellDate("2024-03-05 14:30:09", kind: .dateTime))
        #expect(parseCellDate("2024-03-05 14:30:09+00", kind: .dateTime) == plain)
        let frac = try #require(parseCellDate("2024-03-05 14:30:09.5+00", kind: .dateTime))
        #expect(frac == plain.addingTimeInterval(0.5))
    }

    @Test func malformedFractionReturnsNil() {
        #expect(parseCellDate("2024-03-05 14:30:09.abc", kind: .dateTime) == nil)
        #expect(parseCellDate("2024-03-05 14:30:09.1234567", kind: .dateTime) == nil)
        #expect(parseCellDate("2024-03-05 14:30:09.", kind: .dateTime) == nil)
    }

    // MARK: - JSON 校验

    @Test func validJSONText() {
        #expect(isValidJSONText("{\"a\":1}"))
        #expect(isValidJSONText("[1,2,3]"))
        #expect(isValidJSONText("  { \"nested\": { \"x\": [true, null] } }  "))
        #expect(isValidJSONText("42"))
        #expect(isValidJSONText("\"scalar\""))
        #expect(isValidJSONText("true"))
    }

    @Test func invalidJSONText() {
        #expect(!isValidJSONText("{a:1}"))
        #expect(!isValidJSONText("{\"a\":}"))
        #expect(!isValidJSONText(""))
        #expect(!isValidJSONText("[1,2"))
    }
}