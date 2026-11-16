import Foundation
import Testing
import NIOCore
import PostgresNIO
import MySQLNIO
@testable import DatabaseManagerPlugin

// P2-2 驱动二进制解码单元测试（手工构造线上载荷，无需 Docker）：
// - MySQL 日期/时间二进制协议（长度字节已剥离）→ 文本；
// - PG timestamp/date/time/uuid 二进制 → UTC 文本（timestamptz 附 +00）；
// - PG 二进制数组 → 文本字面量（引号/转义/NULL/多维/numeric）；
// - String 兜底拒绝含控制字符的二进制乱码。
@Suite struct DriverBinaryDecodeTests {
    // MARK: - 构造工具

    private func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var b = ByteBuffer()
        b.writeBytes(bytes)
        return b
    }

    private func pgCell(_ b: ByteBuffer, _ type: PostgresDataType) -> PostgresCell {
        PostgresCell(bytes: b, dataType: type, format: .binary, columnName: "c", columnIndex: 0)
    }

    private func int32Bytes(_ v: Int32) -> [UInt8] {
        var b = ByteBuffer()
        b.writeInteger(v)
        return b.readBytes(length: 4)!
    }

    private func int64Bytes(_ v: Int64) -> [UInt8] {
        var b = ByteBuffer()
        b.writeInteger(v)
        return b.readBytes(length: 8)!
    }

    /// 一维数组载荷：ndim/hasNull/元素OID/维度，随后每元素 Int32 长度 + 载荷（-1 = NULL）。
    private func arrayBytes(elementOID: UInt32, elements: [[UInt8]?]) -> [UInt8] {
        var b = ByteBuffer()
        b.writeInteger(Int32(1))
        b.writeInteger(Int32(elements.contains(where: { $0 == nil }) ? 1 : 0))
        b.writeInteger(elementOID)
        b.writeInteger(Int32(elements.count))
        b.writeInteger(Int32(1))
        for e in elements {
            if let e {
                b.writeInteger(Int32(e.count))
                b.writeBytes(e)
            } else {
                b.writeInteger(Int32(-1))
            }
        }
        return b.readBytes(length: b.readableBytes)!
    }

    // MARK: - MySQL 时间二进制

    @Test func mysqlDatetimeBinaryPayload() {
        var b = ByteBuffer()
        b.writeInteger(UInt16(2024), endianness: .little)
        b.writeBytes([3, 5, 14, 30, 9] as [UInt8])
        let data = MySQLData(type: .datetime, buffer: b)
        #expect(MySQLConnection.temporalText(data, isTime: false) == "2024-03-05 14:30:09")
        #expect(MySQLConnection.convertValue(data, columnType: .datetime) == .string("2024-03-05 14:30:09"))
    }

    @Test func mysqlDateOnlyAndMicroseconds() {
        let date = MySQLData(type: .date, buffer: buffer([0xE8, 0x07, 3, 5]))
        #expect(MySQLConnection.temporalText(date, isTime: false) == "2024-03-05")

        var b = ByteBuffer()
        b.writeInteger(UInt16(2024), endianness: .little)
        b.writeBytes([3, 5, 14, 30, 9] as [UInt8])
        b.writeInteger(UInt32(500_000), endianness: .little)
        let dt = MySQLData(type: .datetime, buffer: b)
        #expect(MySQLConnection.temporalText(dt, isTime: false) == "2024-03-05 14:30:09.500000")
    }

    @Test func mysqlTimeBinaryWithDaysAndSign() {
        // 8 字节：符号 + 天(LE32) + 时分秒；32 小时 = 1 天 + 8 小时。
        var b = ByteBuffer()
        b.writeBytes([1] as [UInt8])
        b.writeInteger(UInt32(1), endianness: .little)
        b.writeBytes([8, 15, 42] as [UInt8])
        let time = MySQLData(type: .time, buffer: b)
        #expect(MySQLConnection.temporalText(time, isTime: true) == "-32:15:42")

        let zero = MySQLData(type: .time, buffer: ByteBuffer())
        #expect(MySQLConnection.temporalText(zero, isTime: true) == "00:00:00")
        let zeroDate = MySQLData(type: .date, buffer: ByteBuffer())
        #expect(MySQLConnection.temporalText(zeroDate, isTime: false) == "0000-00-00 00:00:00")
    }

    @Test func mysqlTextProtocolPassthrough() {
        var b = ByteBuffer()
        b.writeString("2024-01-01 08:00:00")
        let data = MySQLData(type: .datetime, format: .text, buffer: b)
        #expect(MySQLConnection.temporalText(data, isTime: false) == "2024-01-01 08:00:00")
    }

    // MARK: - PG 民用历与时间文本

    @Test func civilDateKnownAnchors() {
        #expect(PGConnection.civilDate(daysSince1970: 0) == (1970, 1, 1))
        #expect(PGConnection.civilDate(daysSince1970: -1) == (1969, 12, 31))
        #expect(PGConnection.civilDate(daysSince1970: 10957) == (2000, 1, 1))
        #expect(PGConnection.civilDate(daysSince1970: 19787) == (2024, 3, 5))
    }

    @Test func pgTimestampText() {
        // 2024-01-01 08:00:00 UTC = Unix 1704096000；PG 纪元 2000-01-01 = 946684800。
        let micros: Int64 = (1_704_096_000 - 946_684_800) * 1_000_000
        #expect(PGConnection.timestampText(micros: micros, withZone: false) == "2024-01-01 08:00:00")
        #expect(PGConnection.timestampText(micros: micros, withZone: true) == "2024-01-01 08:00:00+00")
        #expect(PGConnection.timestampText(micros: micros + 500_000, withZone: false) == "2024-01-01 08:00:00.5")
        #expect(PGConnection.timestampText(micros: micros + 123_456, withZone: false) == "2024-01-01 08:00:00.123456")
        #expect(PGConnection.timestampText(micros: 0, withZone: false) == "2000-01-01 00:00:00")
        // 纪元前负微秒：借位后仍是 1999-12-31 23:59:59.5。
        #expect(PGConnection.timestampText(micros: -500_000, withZone: false) == "1999-12-31 23:59:59.5")
        // 1970 前：floor 除法保证日期不错位。
        #expect(PGConnection.timestampText(micros: -946_684_801_000_000, withZone: false) == "1969-12-31 23:59:59")
    }

    @Test func pgTimeTextWithZone() {
        let micros: Int64 = (8 * 3600 + 15 * 60 + 42) * 1_000_000
        #expect(PGConnection.timeText(micros: micros, zone: nil) == "08:15:42")
        #expect(PGConnection.timeText(micros: micros + 250_000, zone: nil) == "08:15:42.25")
        #expect(PGConnection.timeText(micros: micros, zone: -7200) == "08:15:42+02:00")
        #expect(PGConnection.timeText(micros: micros, zone: 19800) == "08:15:42-05:30")
        #expect(PGConnection.timeText(micros: micros, zone: 0) == "08:15:42+00:00")
        #expect(PGConnection.timeText(micros: 86_400_000_000, zone: nil) == "24:00:00")
    }

    // MARK: - PG convertCell 分派

    @Test func pgTemporalCellsDecodeToText() {
        let micros: Int64 = (1_704_096_000 - 946_684_800) * 1_000_000
        #expect(PGConnection.convertCell(pgCell(buffer(int64Bytes(micros)), .timestamp)) == .string("2024-01-01 08:00:00"))
        #expect(PGConnection.convertCell(pgCell(buffer(int64Bytes(micros)), .timestamptz)) == .string("2024-01-01 08:00:00+00"))
        // 2024-03-05 距 2000-01-01 为 8830 天。
        #expect(PGConnection.convertCell(pgCell(buffer(int32Bytes(8830)), .date)) == .string("2024-03-05"))
        let timeMicros: Int64 = (8 * 3600 + 15 * 60 + 42) * 1_000_000
        #expect(PGConnection.convertCell(pgCell(buffer(int64Bytes(timeMicros)), .time)) == .string("08:15:42"))
        #expect(PGConnection.convertCell(pgCell(buffer(int64Bytes(timeMicros) + int32Bytes(-7200)), .timetz)) == .string("08:15:42+02:00"))
    }

    @Test func pgUUIDCellDecodesLowercase() {
        let bytes: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
                              0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        #expect(PGConnection.convertCell(pgCell(buffer(bytes), .uuid)) == .string("01234567-89ab-cdef-0123-456789abcdef"))
    }

    @Test func pgIntegerDispatchUnchanged() {
        #expect(PGConnection.convertCell(pgCell(buffer(int32Bytes(42)), .int4)) == .integer(42))
    }

    @Test func pgBinaryGarbageNotShownAsText() {
        // text 类型但载荷含 NUL：String 兜底必须拒绝，落回 BLOB。
        let cell = pgCell(buffer([0x41, 0x00, 0x42]), .text)
        #expect(PGConnection.convertCell(cell) == .data(Data([0x41, 0x00, 0x42])))
        // 用户自定义类型（enum）的纯文本标签仍正常透传。
        let enumCell = pgCell(buffer(Array("happy".utf8)), PostgresDataType(16400))
        #expect(PGConnection.convertCell(enumCell) == .string("happy"))
    }

    // MARK: - PG 数组

    @Test func pgIntArrayLiteral() {
        let bytes = arrayBytes(elementOID: 23, elements: [int32Bytes(1), int32Bytes(2), int32Bytes(3)])
        #expect(PGConnection.convertCell(pgCell(buffer(bytes), .int4Array)) == .string("{1,2,3}"))
        let withNull = arrayBytes(elementOID: 23, elements: [int32Bytes(1), nil, int32Bytes(3)])
        #expect(PGConnection.convertCell(pgCell(buffer(withNull), .int4Array)) == .string("{1,NULL,3}"))
    }

    @Test func pgEmptyArray() {
        var b = ByteBuffer()
        b.writeInteger(Int32(0))
        b.writeInteger(Int32(0))
        b.writeInteger(UInt32(23))
        #expect(PGConnection.convertCell(pgCell(b, .int4Array)) == .string("{}"))
    }

    @Test func pgTextArrayQuotingAndEscaping() {
        let elems: [[UInt8]?] = [Array("a".utf8), Array("b c".utf8), Array("NULL".utf8), Array("".utf8)]
        let bytes = arrayBytes(elementOID: 25, elements: elems)
        // PG 只在必要时加引号：普通 a 不带引号，空串/NULL/含空白必须带。
        #expect(PGConnection.convertCell(pgCell(buffer(bytes), .textArray)) == .string(#"{a,"b c","NULL",""}"#))

        let tricky: [[UInt8]?] = [Array("he\"llo".utf8), Array("back\\slash".utf8), Array("{x}".utf8)]
        let trickyBytes = arrayBytes(elementOID: 25, elements: tricky)
        #expect(PGConnection.convertCell(pgCell(buffer(trickyBytes), .textArray)) == .string(#"{"he\"llo","back\\slash","{x}"}"#))
    }

    @Test func pgBoolFloatAndNumericArrays() {
        let bools = arrayBytes(elementOID: 16, elements: [[1], [0]])
        #expect(PGConnection.convertCell(pgCell(buffer(bools), .boolArray)) == .string("{t,f}"))

        var f8 = ByteBuffer()
        f8.writeInteger(Double(1.5).bitPattern)
        let floats = arrayBytes(elementOID: 701, elements: [f8.readBytes(length: 8)!])
        #expect(PGConnection.convertCell(pgCell(buffer(floats), .float8Array)) == .string("{1.5}"))

        // 12345.67 = 万进制组 [1, 2345, 6700]，weight=1，dscale=2。
        var num = ByteBuffer()
        num.writeInteger(Int16(3))
        num.writeInteger(Int16(1))
        num.writeInteger(UInt16(0x0000))
        num.writeInteger(Int16(2))
        num.writeInteger(UInt16(1))
        num.writeInteger(UInt16(2345))
        num.writeInteger(UInt16(6700))
        let nums = arrayBytes(elementOID: 1700, elements: [num.readBytes(length: num.readableBytes)!])
        #expect(PGConnection.convertCell(pgCell(buffer(nums), .numericArray)) == .string("{12345.67}"))

        // -0.5：组 [5000]，weight=-1，dscale=1，负号。
        var neg = ByteBuffer()
        neg.writeInteger(Int16(1))
        neg.writeInteger(Int16(-1))
        neg.writeInteger(UInt16(0x4000))
        neg.writeInteger(Int16(1))
        neg.writeInteger(UInt16(5000))
        let negs = arrayBytes(elementOID: 1700, elements: [neg.readBytes(length: neg.readableBytes)!])
        #expect(PGConnection.convertCell(pgCell(buffer(negs), .numericArray)) == .string("{-0.5}"))
    }

    @Test func pgMultidimensionalAndTimestampArrays() {
        var b = ByteBuffer()
        b.writeInteger(Int32(2))
        b.writeInteger(Int32(0))
        b.writeInteger(UInt32(23))
        b.writeInteger(Int32(2)); b.writeInteger(Int32(1))
        b.writeInteger(Int32(2)); b.writeInteger(Int32(1))
        for v in [1, 2, 3, 4] as [Int32] {
            b.writeInteger(Int32(4))
            b.writeInteger(v)
        }
        #expect(PGConnection.convertCell(pgCell(b, .int4Array)) == .string("{{1,2},{3,4}}"))

        let ts = arrayBytes(elementOID: 1114, elements: [int64Bytes(0)])
        #expect(PGConnection.convertCell(pgCell(buffer(ts), .timestampArray)) == .string("{2000-01-01 00:00:00}"))
    }

    @Test func pgJsonbArraySkipsVersionByte() {
        var payload: [UInt8] = [1]
        payload.append(contentsOf: Array(#"{"a":1}"#.utf8))
        let bytes = arrayBytes(elementOID: 3802, elements: [payload])
        #expect(PGConnection.convertCell(pgCell(buffer(bytes), .jsonbArray)) == .string(#"{"{\"a\":1}"}"#))
    }

    @Test func pgUnsupportedArrayFallsBackToBlob() {
        // point 数组（元素 OID 600）不支持渲染 → 整个单元落回 BLOB 而不是乱码。
        let bytes = arrayBytes(elementOID: 600, elements: [int64Bytes(0) + int64Bytes(0)])
        let cell = pgCell(buffer(bytes), PostgresDataType(1017))
        if case .data = PGConnection.convertCell(cell) {} else {
            Issue.record("expected .data fallback for unsupported array element type")
        }
    }
}