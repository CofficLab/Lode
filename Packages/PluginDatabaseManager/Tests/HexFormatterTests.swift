import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-5 hex 格式化纯函数验收：偏移 / 十六进制列 / ASCII 列、
// 末行补齐对齐、非打印字符占位、空数据、非零 startIndex 的 Data 切片。

struct HexFormatterTests {
    @Test func fullRowHexAndAscii() {
        let data = Data((0..<32).map(UInt8.init))
        let row = HexFormatter.row(data, at: 0)
        #expect(row.offset == 0)
        #expect(row.hex == "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f")
        #expect(row.ascii == String(repeating: ".", count: 16))
        let second = HexFormatter.row(data, at: 1)
        #expect(second.offset == 16)
        #expect(second.hex.hasPrefix("10 11"))
    }

    @Test func printableAsciiAndPartialRowPadding() {
        let data = Data("Hello, World!".utf8)
        let row = HexFormatter.row(data, at: 0)
        #expect(row.ascii == "Hello, World!")
        #expect(row.hex.hasPrefix("48 65 6c 6c 6f 2c 20 57 6f 72 6c 64 21"))
        // 13 字节 + 3 个双空格占位，列宽与满行一致
        #expect(row.hex.count == 16 * 2 + 15)
        #expect(row.hex.hasSuffix("      "))
    }

    @Test func rowCountBoundaries() {
        #expect(HexFormatter.rowCount(Data()) == 0)
        #expect(HexFormatter.rowCount(Data(repeating: 0, count: 16)) == 1)
        #expect(HexFormatter.rowCount(Data(repeating: 0, count: 17)) == 2)
    }

    @Test func hexStringLowercaseContinuous() {
        #expect(HexFormatter.hexString(Data([0xDE, 0xAD, 0x00])) == "dead00")
        #expect(HexFormatter.hexString(Data()) == "")
    }

    @Test func respectsDataSliceStartIndex() {
        let base = Data((0..<20).map(UInt8.init))
        let slice = base[5...]
        #expect(slice.startIndex == 5)
        let row = HexFormatter.row(slice, at: 0)
        #expect(row.offset == 0)
        #expect(row.hex.hasPrefix("05 06 07"))
        #expect(HexFormatter.rowCount(slice) == 1)
    }
}