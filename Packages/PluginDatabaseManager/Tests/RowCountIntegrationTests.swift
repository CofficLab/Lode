import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-6 真实引擎行数计数验收：
// - SQLite 无估算 → 降级精确 COUNT，结果正确且标记为非估算；
// - PG reltuples（ANALYZE 后）→ 估算标记 + 数值；按需精确计数覆盖；带筛选强制精确；
// - MySQL information_schema.TABLE_ROWS → 估算标记；按需精确计数得到精确值。

private func rcPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct RowCountIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    @Test func sqliteFallsBackToExactCount() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-rc-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "rc", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE rc_items (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO rc_items (id, name) VALUES (1,'a'),(2,'b'),(3,'c')", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "rc_items"))
        await vm.refreshTableRowCount()
        #expect(vm.tableRowCount == 3)
        #expect(vm.tableRowCountIsApproximate == false)
    }

    @Test(.enabled(if: rcPort("LODE_TEST_PG_PORT") != nil))
    func postgresApproximateThenExactAndFilter() async throws {
        let port = try #require(rcPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "rc", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS rc_pg", params: nil)
        _ = try await other.execute("CREATE TABLE rc_pg (id INT PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO rc_pg (id, name) VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d'),(5,'e')", params: nil)
        _ = try await other.execute("ANALYZE rc_pg", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "rc_pg", schema: "public"))
        await vm.refreshTableRowCount()
        #expect(vm.tableRowCountIsApproximate == true)
        #expect(vm.tableRowCount == 5)

        // 按需精确计数覆盖估算标记
        await vm.refreshExactRowCount()
        #expect(vm.tableRowCountIsApproximate == false)
        #expect(vm.tableRowCount == 5)

        // 带筛选 → 强制精确计数（估算无法反映过滤后的行数）
        vm.tableFilter = TableFilter(useRawWhere: true, rawWhere: "id > 2")
        await vm.refreshTableRowCount()
        #expect(vm.tableRowCountIsApproximate == false)
        #expect(vm.tableRowCount == 3)
        _ = try await other.execute("DROP TABLE IF EXISTS rc_pg", params: nil)
    }

    @Test(.enabled(if: rcPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlApproximateThenExact() async throws {
        let port = try #require(rcPort("LODE_TEST_MYSQL_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "rc", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS rc_my", params: nil)
        _ = try await other.execute("CREATE TABLE rc_my (id INT PRIMARY KEY, name VARCHAR(32)) ENGINE=InnoDB", params: nil)
        _ = try await other.execute("INSERT INTO rc_my (id, name) VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d')", params: nil)
        _ = try await other.execute("ANALYZE TABLE rc_my", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "rc_my", database: "testdb"))
        await vm.refreshTableRowCount()
        #expect(vm.tableRowCountIsApproximate == true)
        #expect((vm.tableRowCount ?? -1) >= 0)

        await vm.refreshExactRowCount()
        #expect(vm.tableRowCountIsApproximate == false)
        #expect(vm.tableRowCount == 4)
        _ = try await other.execute("DROP TABLE IF EXISTS rc_my", params: nil)
    }
}