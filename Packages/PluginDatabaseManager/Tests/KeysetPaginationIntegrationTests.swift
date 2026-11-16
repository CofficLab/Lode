import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-6 真实引擎 keyset 分页验收：
// - 按主键排序 + 开启 keyset → 翻页用 WHERE key > last（无 OFFSET），前进/回退正确；
// - 降序用 < 游标；筛选与游标条件正确合并；
// - SQLite / PostgreSQL / MySQL 三引擎一致。

private func ksPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct KeysetPaginationIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func ids(_ vm: DatabaseViewModel) -> [Int] {
        guard let r = vm.queryResult, let idx = r.columns.firstIndex(of: "id") else { return [] }
        return r.rows.compactMap { row in
            guard idx < row.count, case .integer(let v) = row[idx] else { return nil }
            return v
        }
    }

    @Test func sqliteKeysetForwardBackwardAndDesc() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-ks-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "ks", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ks_items (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        let values = (1...25).map { "(\($0), 'n\($0)')" }.joined(separator: ",")
        _ = try await other.execute("INSERT INTO ks_items (id, name) VALUES \(values)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "ks_items"))
        await vm.toggleSort(column: "id")          // 升序
        await vm.setPageSize(10)
        await vm.setUseKeysetPagination(true)
        #expect(vm.keysetAvailable == true)
        #expect(ids(vm) == Array(1...10))
        #expect(vm.queryText.contains("OFFSET") == false)

        await vm.nextPage()
        #expect(ids(vm) == Array(11...20))
        #expect(vm.queryText.contains("\"id\" >"))
        await vm.nextPage()
        #expect(ids(vm) == Array(21...25))

        await vm.prevPage()
        #expect(ids(vm) == Array(11...20))
        await vm.prevPage()
        #expect(ids(vm) == Array(1...10))
        await vm.prevPage()                          // 首页再回退为无操作
        #expect(ids(vm) == Array(1...10))

        // 降序：升→降
        await vm.toggleSort(column: "id")
        #expect(vm.keysetAvailable == true)
        #expect(ids(vm) == Array((16...25).reversed()))
        await vm.nextPage()
        #expect(ids(vm) == Array((6...15).reversed()))
        #expect(vm.queryText.contains("\"id\" <"))

        // 筛选 + keyset 合并
        await vm.toggleSort(column: "id")            // 降→关
        await vm.toggleSort(column: "id")            // 关→升
        vm.tableFilter = TableFilter(useRawWhere: true, rawWhere: "id > 5")
        await vm.applyFilter()
        #expect(ids(vm) == Array(6...15))
        await vm.nextPage()
        #expect(ids(vm) == Array(16...25))
        #expect(vm.queryText.contains("(id > 5) AND"))
    }

    @Test(.enabled(if: ksPort("LODE_TEST_PG_PORT") != nil))
    func postgresKeysetPaging() async throws {
        let port = try #require(ksPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "ks", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS ks_pg", params: nil)
        _ = try await other.execute("CREATE TABLE ks_pg (id INT PRIMARY KEY, name TEXT)", params: nil)
        let values = (1...25).map { "(\($0), 'n\($0)')" }.joined(separator: ",")
        _ = try await other.execute("INSERT INTO ks_pg (id, name) VALUES \(values)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "ks_pg", schema: "public"))
        await vm.toggleSort(column: "id")
        await vm.setPageSize(10)
        await vm.setUseKeysetPagination(true)
        #expect(vm.keysetAvailable == true)
        #expect(ids(vm) == Array(1...10))
        #expect(vm.queryText.contains("OFFSET") == false)
        await vm.nextPage()
        #expect(ids(vm) == Array(11...20))
        #expect(vm.queryText.contains("\"id\" > $1"))
        await vm.nextPage()
        #expect(ids(vm) == Array(21...25))
        await vm.prevPage()
        #expect(ids(vm) == Array(11...20))
        _ = try await other.execute("DROP TABLE IF EXISTS ks_pg", params: nil)
    }

    @Test(.enabled(if: ksPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlKeysetPaging() async throws {
        let port = try #require(ksPort("LODE_TEST_MYSQL_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "ks", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS ks_my", params: nil)
        _ = try await other.execute("CREATE TABLE ks_my (id INT PRIMARY KEY, name VARCHAR(32)) ENGINE=InnoDB", params: nil)
        let values = (1...25).map { "(\($0), 'n\($0)')" }.joined(separator: ",")
        _ = try await other.execute("INSERT INTO ks_my (id, name) VALUES \(values)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "ks_my", database: "testdb"))
        await vm.toggleSort(column: "id")
        await vm.setPageSize(10)
        await vm.setUseKeysetPagination(true)
        #expect(vm.keysetAvailable == true)
        #expect(ids(vm) == Array(1...10))
        #expect(vm.queryText.contains("OFFSET") == false)
        await vm.nextPage()
        #expect(ids(vm) == Array(11...20))
        #expect(vm.queryText.contains("`id` > ?"))
        await vm.nextPage()
        #expect(ids(vm) == Array(21...25))
        await vm.prevPage()
        #expect(ids(vm) == Array(11...20))
        _ = try await other.execute("DROP TABLE IF EXISTS ks_my", params: nil)
    }
}