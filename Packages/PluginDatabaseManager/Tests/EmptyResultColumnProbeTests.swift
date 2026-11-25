import Foundation
import Testing
@testable import DatabaseManagerPlugin

// 零行 SELECT 必须返回正确的列名且不抛错。
// PostgreSQL 的列探针曾误用 ON COMMIT DROP：autocommit 下临时表建好即被删，
// 随后 ::regclass 查 pg_attribute 报「关系不存在」，使任何空结果查询失败。
// 网络引擎需本地 Docker：LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT；SQLite 始终运行。

private func probePort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct EmptyResultColumnProbeTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        return (DatabaseViewModel(loadSavedConfigs: false, manager: manager), manager)
    }

    /// 空表与「WHERE 不命中」两种零行路径都要推断出列名。
    private func runEmptyResultScenario(connection: any DatabaseConnection, table: String) async throws {
        _ = try await connection.execute("DROP TABLE IF EXISTS \(table)", params: nil)
        _ = try await connection.execute("CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT)", params: nil)

        // 空表：SELECT * 零行。
        let empty = try await connection.query("SELECT * FROM \(table)", params: nil)
        #expect(empty.rows.isEmpty)
        #expect(empty.columns == ["id", "name"])

        // 有行但 WHERE 不命中：同样零行，列名仍要正确。
        _ = try await connection.execute("INSERT INTO \(table) (id, name) VALUES (1, 'x')", params: nil)
        let noMatch = try await connection.query("SELECT * FROM \(table) WHERE id = -1", params: nil)
        #expect(noMatch.rows.isEmpty)
        #expect(noMatch.columns == ["id", "name"])

        // 显式列投影的零行查询。
        let projected = try await connection.query("SELECT name, id FROM \(table) WHERE id = -1", params: nil)
        #expect(projected.rows.isEmpty)
        #expect(projected.columns == ["name", "id"])

        // 表浏览分页自带 LIMIT/OFFSET：列探针不得再重复追加 LIMIT。
        let paged = try await connection.query(
            "SELECT * FROM \(table) WHERE id = -1 LIMIT 100 OFFSET 0",
            params: nil
        )
        #expect(paged.rows.isEmpty)
        #expect(paged.columns == ["id", "name"])

        _ = try await connection.execute("DROP TABLE IF EXISTS \(table)", params: nil)
    }

    @Test(.enabled(if: probePort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlEmptyResultColumns() async throws {
        let port = try #require(probePort("LODE_TEST_MYSQL_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "probe", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runEmptyResultScenario(connection: connection, table: "empty_probe_mysql")
        await viewModel.disconnect()
    }

    @Test(.enabled(if: probePort("LODE_TEST_PG_PORT") != nil))
    func postgresEmptyResultColumns() async throws {
        let port = try #require(probePort("LODE_TEST_PG_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "probe", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runEmptyResultScenario(connection: connection, table: "empty_probe_pg")
        await viewModel.disconnect()
    }

    @Test func sqliteEmptyResultColumns() async throws {
        let (viewModel, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-probe-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "probe", type: .sqlite, database: path)
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runEmptyResultScenario(connection: connection, table: "empty_probe_sqlite")
        await viewModel.disconnect()
    }
}