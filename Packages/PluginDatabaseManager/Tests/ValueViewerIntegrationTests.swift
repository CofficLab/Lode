import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-5 真实引擎取值路径验收：
// - SQLite TEXT 大 JSON（~1MB）经网格读取 → Task.detached 构建 JSON 树 →
//   根类型 / 搜索 / 折叠可见行正确（构建不占主线程）；
// - SQLite BLOB → hex 行与原始字节一致；
// - PG JSONB（env 门控）解码后同样可建树。

private func vvPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func vvText(_ value: DatabaseValue) -> String? {
    switch value {
    case .string(let s): return s
    case .data(let d): return String(data: d, encoding: .utf8)
    default: return nil
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ValueViewerIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    /// 与查看器相同的离主线程构建路径。
    private func buildOffMain(_ text: String) async -> [JSONTreeNode]? {
        await Task.detached(priority: .userInitiated) {
            JSONValueTree.build(from: text)
        }.value
    }

    @Test func sqliteLargeJSONAndBlobViewing() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-vv-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "vv", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }

        // ~1MB JSON 文档 + 二进制 BLOB
        let payload = String(repeating: "row-data-", count: 120)
        var records: [String] = []
        for i in 0..<1100 {
            records.append("{\"id\":\(i),\"label\":\"item-\(i)\",\"blob_text\":\"\(payload)\"}")
        }
        let bigJSON = "{\"records\":[" + records.joined(separator: ",") + "]}"
        #expect(bigJSON.utf8.count > 900_000)

        _ = try await other.execute("CREATE TABLE vv_cells (id INTEGER PRIMARY KEY, doc TEXT, bin BLOB)", params: nil)
        _ = try await other.execute("INSERT INTO vv_cells (id, doc, bin) VALUES (1, ?, ?)", params: [.string(bigJSON), .data(Data([0x00, 0x41, 0xFF, 0x7E]))])

        await vm.openObject(DatabaseObject(kind: .table, name: "vv_cells"))
        let result = try #require(vm.queryResult)
        let row = try #require(result.rows.first)
        let docIndex = try #require(result.columns.firstIndex(of: "doc"))
        let binIndex = try #require(result.columns.firstIndex(of: "bin"))
        let docText = try #require(vvText(row[docIndex]))

        // 离主线程建树：根对象 → records 数组 → 1100 条
        let nodes = try #require(await buildOffMain(docText))
        #expect(nodes[0].kind == .object)
        let recordsNode = try #require(nodes.first { $0.key == "records" })
        #expect(recordsNode.kind == .array)
        #expect(recordsNode.childCount == 1100)
        let hits = JSONValueTree.search(nodes, query: "item-1099")
        #expect(hits.count == 1)
        #expect(nodes[hits[0]].path == "$.records[1099].label")
        // 折叠态：根 + records + 1100 个元素对象
        let visible = JSONValueTree.visibleRows(nodes, expanded: [0, recordsNode.id])
        #expect(visible.count == 1102)

        // BLOB → hex 行
        guard case .data(let blob) = row[binIndex] else {
            Issue.record("bin column should be .data")
            return
        }
        #expect(HexFormatter.rowCount(blob) == 1)
        let hexRow = HexFormatter.row(blob, at: 0)
        #expect(hexRow.hex.hasPrefix("00 41 ff 7e"))
        #expect(hexRow.ascii == ".A.~")
        #expect(HexFormatter.hexString(blob) == "0041ff7e")
    }

    @Test(.enabled(if: vvPort("LODE_TEST_PG_PORT") != nil))
    func pgJSONBViewing() async throws {
        let port = try #require(vvPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "vv", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }

        _ = try await other.execute("DROP TABLE IF EXISTS vv_pg", params: nil)
        _ = try await other.execute("CREATE TABLE vv_pg (id INT PRIMARY KEY, doc JSONB)", params: nil)
        defer { Task { _ = try? await other.execute("DROP TABLE IF EXISTS vv_pg", params: nil) } }
        _ = try await other.execute(
            "INSERT INTO vv_pg (id, doc) VALUES (1, '{\"users\":[{\"name\":\"Alice\"},{\"name\":\"Bob\"}]}')", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "vv_pg", schema: "public"))
        let result = try #require(vm.queryResult)
        let row = try #require(result.rows.first)
        let docIndex = try #require(result.columns.firstIndex(of: "doc"))
        let docText = try #require(vvText(row[docIndex]))
        let nodes = try #require(await buildOffMain(docText))
        #expect(nodes[0].kind == .object)
        let hits = JSONValueTree.search(nodes, query: "Bob")
        #expect(hits.count == 1)
        #expect(nodes[hits[0]].path == "$.users[1].name")
        let copied = try #require(JSONValueTree.copyValue(nodes, at: 0))
        let a = try #require(JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any])
        let b = try #require(JSONSerialization.jsonObject(with: Data(docText.utf8)) as? [String: Any])
        #expect((a as NSDictionary) == (b as NSDictionary))
    }
}