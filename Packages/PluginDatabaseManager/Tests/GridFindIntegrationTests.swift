import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-7 真实引擎网格查找验收：
// - 当前页客户端匹配 + 活动匹配导航（循环）；
// - 全量服务端 LIKE 过滤（与用户筛选 AND 合并），行数反映过滤结果；
// - SQLite / PostgreSQL / MySQL 三引擎方言占位符一致。

private func gfPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct GridFindIntegrationTests {
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

    @Test func sqliteCurrentPageFindAndNavigation() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-gf-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "gf", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE gf_items (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        let values = (1...12).map { "(\($0), '\($0 % 3 == 0 ? "banana" : "apple")-\($0)')" }.joined(separator: ",")
        _ = try await other.execute("INSERT INTO gf_items (id, name) VALUES \(values)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "gf_items"))
        #expect(vm.queryResult?.rows.count == 12)

        vm.showGridFind()
        #expect(vm.gridFindVisible)
        vm.gridFindText = "banana"
        await vm.runGridFind()
        // banana 在 id 3/6/9/12 → 行索引 2/5/8/11，name 列索引 1。
        #expect(vm.gridFindMatches == [
            GridFind.CellPosition(row: 2, col: 1),
            GridFind.CellPosition(row: 5, col: 1),
            GridFind.CellPosition(row: 8, col: 1),
            GridFind.CellPosition(row: 11, col: 1)
        ])
        #expect(vm.activeGridFindMatch == GridFind.CellPosition(row: 2, col: 1))
        vm.nextGridFindMatch()
        #expect(vm.gridFindMatchIndex == 1)
        vm.prevGridFindMatch()
        #expect(vm.gridFindMatchIndex == 0)
        vm.prevGridFindMatch()                       // 循环到末尾
        #expect(vm.gridFindMatchIndex == 3)

        vm.closeGridFind()
        #expect(vm.gridFindVisible == false)
        #expect(vm.gridFindMatches.isEmpty)
        #expect(vm.gridFindText.isEmpty)
    }

    @Test func sqliteServerFindMergesWithFilter() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-gfs-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "gfs", type: .sqlite, database: path)
        await vm.connect(config: config)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE gf_search (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        let values = (1...30).map { "(\($0), '\($0 % 5 == 0 ? "target" : "other")-\($0)')" }.joined(separator: ",")
        _ = try await other.execute("INSERT INTO gf_search (id, name) VALUES \(values)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "gf_search"))
        await vm.setPageSize(10)
        vm.showGridFind()
        vm.gridFindScope = .allRows
        vm.gridFindText = "target"
        await vm.runGridFind()
        #expect(ids(vm) == [5, 10, 15, 20, 25, 30])
        #expect(vm.queryText.contains("LIKE"))
        await vm.refreshExactRowCount()
        #expect(vm.tableRowCount == 6)
        #expect(vm.tableRowCountIsApproximate == false)

        // 与用户筛选 AND 合并：target 且 id > 10。
        vm.tableFilter = TableFilter(useRawWhere: true, rawWhere: "id > 10")
        await vm.applyFilter()
        #expect(ids(vm) == [15, 20, 25, 30])
        #expect(vm.queryText.contains("(id > 10) AND"))

        // 关闭查找清除服务端过滤；同时清空用户筛选后重载，恢复全量首页。
        vm.closeGridFind()
        vm.tableFilter = .empty
        await vm.loadTablePage()
        #expect(ids(vm) == Array(1...10))
    }

    @Test(.enabled(if: gfPort("LODE_TEST_PG_PORT") != nil))
    func postgresServerFind() async throws {
        let port = try #require(gfPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "gf", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS gf_pg", params: nil)
        _ = try await other.execute("CREATE TABLE gf_pg (id INT PRIMARY KEY, name TEXT)", params: nil)
        let values = (1...20).map { "(\($0), '\($0 % 4 == 0 ? "target" : "other")-\($0)')" }.joined(separator: ",")
        _ = try await other.execute("INSERT INTO gf_pg (id, name) VALUES \(values)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "gf_pg", schema: "public"))
        await vm.setPageSize(10)
        vm.showGridFind()
        vm.gridFindScope = .allRows
        vm.gridFindText = "target"
        await vm.runGridFind()
        #expect(ids(vm) == [4, 8, 12, 16, 20])
        #expect(vm.queryText.contains("LIKE LOWER($1)"))
        _ = try await other.execute("DROP TABLE IF EXISTS gf_pg", params: nil)
    }

    @Test(.enabled(if: gfPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlServerFind() async throws {
        let port = try #require(gfPort("LODE_TEST_MYSQL_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "gf", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS gf_my", params: nil)
        _ = try await other.execute("CREATE TABLE gf_my (id INT PRIMARY KEY, name VARCHAR(32)) ENGINE=InnoDB", params: nil)
        let values = (1...20).map { "(\($0), '\($0 % 4 == 0 ? "target" : "other")-\($0)')" }.joined(separator: ",")
        _ = try await other.execute("INSERT INTO gf_my (id, name) VALUES \(values)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "gf_my", database: "testdb"))
        await vm.setPageSize(10)
        vm.showGridFind()
        vm.gridFindScope = .allRows
        vm.gridFindText = "target"
        await vm.runGridFind()
        #expect(ids(vm) == [4, 8, 12, 16, 20])
        #expect(vm.queryText.contains("LIKE LOWER(?)"))
        _ = try await other.execute("DROP TABLE IF EXISTS gf_my", params: nil)
    }
}