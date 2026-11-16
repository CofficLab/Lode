import Foundation
import Testing
@testable import DatabaseManagerPlugin

// MySQL 8 的 information_schema 文本列按 blob 线上类型返回 .data；
// 解码器必须按 UTF-8 还原，否则列类型/主键/可空/注释全部静默丢失。

@Suite
struct SchemaIntrospectionTests {
    @Test func decodesBlobBackedCatalogText() {
        let row: [DatabaseValue] = [.data(Data("tinyint(1)".utf8)), .data(Data("YES".utf8))]
        #expect(SchemaRowDecoder.string(row, at: 0) == "tinyint(1)")
        #expect(SchemaRowDecoder.string(row, at: 1) == "YES")
    }

    @Test func decodesPlainCatalogValues() {
        let row: [DatabaseValue] = [.string("int"), .integer(3), .double(2.5), .bool(true), .null]
        #expect(SchemaRowDecoder.string(row, at: 0) == "int")
        #expect(SchemaRowDecoder.string(row, at: 1) == "3")
        #expect(SchemaRowDecoder.string(row, at: 2) == "2.5")
        #expect(SchemaRowDecoder.string(row, at: 3) == "true")
        #expect(SchemaRowDecoder.string(row, at: 4) == nil)
        #expect(SchemaRowDecoder.string(row, at: 9) == nil)
        #expect(SchemaRowDecoder.int(row, at: 1) == 3)
        #expect(SchemaRowDecoder.int(row, at: 0) == nil)
    }

    @Test func invalidUTF8BlobDecodesToNil() {
        let row: [DatabaseValue] = [.data(Data([0xFF, 0xFE]))]
        #expect(SchemaRowDecoder.string(row, at: 0) == nil)
    }
}