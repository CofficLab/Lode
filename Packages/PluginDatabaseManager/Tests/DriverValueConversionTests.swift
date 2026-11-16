import Foundation
import Testing
@testable import DatabaseManagerPlugin

// 线上类型驱动的值转换回归：字符串优先的试探式转换会把数字吞成文本
// （MySQL 文本协议、PG 的 String 解码对 int4 也成功）。

#if canImport(MySQLNIO)
import MySQLNIO
import NIOCore

@Suite
struct MySQLValueConversionTests {
    private func textData(_ type: MySQLProtocol.DataType, _ text: String) -> MySQLData {
        MySQLData(type: type, format: .text, buffer: ByteBuffer(string: text))
    }

    @Test func integerColumnInTextProtocol() {
        #expect(MySQLConnection.convertValue(textData(.longlong, "42"), columnType: .longlong) == .integer(42))
        #expect(MySQLConnection.convertValue(textData(.int24, "-7"), columnType: .int24) == .integer(-7))
        #expect(MySQLConnection.convertValue(textData(.tiny, "1"), columnType: .tiny) == .integer(1))
    }

    @Test func integerColumnInBinaryProtocol() {
        #expect(MySQLConnection.convertValue(MySQLData(int: 9_007_199_254_740_993), columnType: .longlong) == .integer(9_007_199_254_740_993))
    }

    @Test func floatAndDecimalColumns() {
        #expect(MySQLConnection.convertValue(textData(.double, "3.5"), columnType: .double) == .double(3.5))
        #expect(MySQLConnection.convertValue(textData(.newdecimal, "12.75"), columnType: .newdecimal) == .double(12.75))
    }

    @Test func numericLookingTextStaysString() {
        #expect(MySQLConnection.convertValue(textData(.varString, "42"), columnType: .varString) == .string("42"))
        #expect(MySQLConnection.convertValue(textData(.varchar, "3.5"), columnType: .varchar) == .string("3.5"))
    }

    @Test func nullValueInNumericColumn() {
        #expect(MySQLConnection.convertValue(.null, columnType: .longlong) == .null)
    }

    @Test func blobKeepsRawBytes() {
        let data = MySQLData(type: .blob, format: .text, buffer: ByteBuffer(bytes: [0x00, 0xFF, 0x10]))
        #expect(MySQLConnection.convertValue(data, columnType: .blob) == .data(Data([0x00, 0xFF, 0x10])))
    }

    @Test func dateAndJsonStayString() {
        #expect(MySQLConnection.convertValue(textData(.date, "2026-01-02"), columnType: .date) == .string("2026-01-02"))
        #expect(MySQLConnection.convertValue(textData(.json, "{\"a\":1}"), columnType: .json) == .string("{\"a\":1}"))
    }
}
#endif

#if canImport(PostgresNIO)
import NIOCore
import PostgresNIO

@Suite
struct PGValueConversionTests {
    private func textCell(_ type: PostgresDataType, _ text: String) -> PostgresCell {
        PostgresCell(bytes: ByteBuffer(string: text), dataType: type, format: .text, columnName: "c", columnIndex: 0)
    }

    @Test func integerColumnsInTextFormat() {
        #expect(PGConnection.convertCell(textCell(.int4, "42")) == .integer(42))
        #expect(PGConnection.convertCell(textCell(.int2, "-7")) == .integer(-7))
        #expect(PGConnection.convertCell(textCell(.int8, "9007199254740993")) == .integer(9_007_199_254_740_993))
    }

    @Test func integerColumnInBinaryFormat() {
        var buffer = ByteBufferAllocator().buffer(capacity: 4)
        buffer.writeInteger(Int32(7), endianness: .big)
        let cell = PostgresCell(bytes: buffer, dataType: .int4, format: .binary, columnName: "c", columnIndex: 0)
        #expect(PGConnection.convertCell(cell) == .integer(7))
    }

    @Test func floatAndNumericColumns() {
        #expect(PGConnection.convertCell(textCell(.float8, "3.5")) == .double(3.5))
        #expect(PGConnection.convertCell(textCell(.float4, "0.5")) == .double(0.5))
        #expect(PGConnection.convertCell(textCell(.numeric, "12.75")) == .double(12.75))
    }

    @Test func boolColumn() {
        #expect(PGConnection.convertCell(textCell(.bool, "t")) == .bool(true))
        #expect(PGConnection.convertCell(textCell(.bool, "f")) == .bool(false))
    }

    @Test func numericLookingTextStaysString() {
        #expect(PGConnection.convertCell(textCell(.text, "42")) == .string("42"))
        #expect(PGConnection.convertCell(textCell(.varchar, "3.5")) == .string("3.5"))
    }

    @Test func nullCell() {
        let cell = PostgresCell(bytes: nil, dataType: .int4, format: .text, columnName: "c", columnIndex: 0)
        #expect(PGConnection.convertCell(cell) == .null)
    }

    @Test func byteaKeepsRawBytes() {
        let cell = PostgresCell(bytes: ByteBuffer(bytes: [0x00, 0xFF]), dataType: .bytea, format: .binary, columnName: "c", columnIndex: 0)
        #expect(PGConnection.convertCell(cell) == .data(Data([0x00, 0xFF])))
    }

    @Test func jsonStaysString() {
        #expect(PGConnection.convertCell(textCell(.jsonb, "{\"a\":1}")) == .string("{\"a\":1}"))
    }
}
#endif