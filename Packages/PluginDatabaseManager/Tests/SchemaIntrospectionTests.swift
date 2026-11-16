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

    // MARK: - 真实引擎：MySQL catalog 元数据完整

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"] != nil))
    func mysqlDescribeTableReportsRealMetadata() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"].flatMap(Int.init))
        let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await conn.close() } }
        _ = try await conn.execute("DROP TABLE IF EXISTS si_meta", params: nil)
        _ = try await conn.execute("CREATE TABLE si_meta (id INTEGER PRIMARY KEY, name VARCHAR(64) NOT NULL COMMENT 'who', flag BOOLEAN)", params: nil)
        defer { Task { _ = try? await conn.execute("DROP TABLE IF EXISTS si_meta", params: nil) } }
        let schema = try await MySQLIntrospector().describeTable(
            DatabaseObject(kind: .table, name: "si_meta", database: "testdb"), in: conn)
        let id = try #require(schema.columns.first { $0.name == "id" })
        #expect(id.isPrimaryKey)
        #expect(id.dataType.contains("int"))
        let name = try #require(schema.columns.first { $0.name == "name" })
        #expect(name.dataType == "varchar(64)")
        #expect(name.isNullable == false)
        #expect(name.comment == "who")
        // column_type 保留 tinyint(1) 修饰符，BOOLEAN 语义不丢。
        let flag = try #require(schema.columns.first { $0.name == "flag" })
        #expect(flag.dataType == "tinyint(1)")
    }
}