import Foundation
import Testing
@testable import DatabaseManagerPlugin

// 需要本地 Docker 引擎：LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT。
// 真实表 2500 行验证默认 LIMIT 注入与增量加载窗口。

private func testPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct EditorPagingIntegrationTests {
    private func makeViewModel() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        return (DatabaseViewModel(loadSavedConfigs: false, manager: manager), manager)
    }

    private func uniqueTable() -> String {
        "lode_paging_\(UUID().uuidString.prefix(8).lowercased())"
    }

    private func expectWindow(_ viewModel: DatabaseViewModel, rows: Int, lastID: Int) {
        #expect(viewModel.queryResult?.rows.count == rows)
        #expect(viewModel.editorFetchedRows == rows)
        #expect(viewModel.queryResult?.rows.last?.first == .integer(lastID))
    }

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlDefaultLimitAndLoadMore() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        let (viewModel, manager) = await makeViewModel()
        let config = DatabaseConfig(
            name: "paging-it", type: .mysql, host: "127.0.0.1", port: port,
            database: "testdb", username: "root", password: "test"
        )
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        let table = uniqueTable()

        _ = try await connection.execute("CREATE TABLE \(table) (id INT PRIMARY KEY)", params: nil)
        let values = (1...2500).map { "(\($0))" }.joined(separator: ",")
        _ = try await connection.execute("INSERT INTO \(table) (id) VALUES \(values)", params: nil)

        viewModel.queryText = "SELECT id FROM \(table) ORDER BY id"
        await viewModel.executeQuery()
        expectWindow(viewModel, rows: 1000, lastID: 1000)
        #expect(viewModel.editorHasMore)
        #expect(viewModel.queryResult?.rows.first?.first == .integer(1))

        await viewModel.loadMoreEditorResults()
        expectWindow(viewModel, rows: 2000, lastID: 2000)
        #expect(viewModel.editorHasMore)

        await viewModel.loadMoreEditorResults()
        expectWindow(viewModel, rows: 2500, lastID: 2500)
        #expect(!viewModel.editorHasMore)
        #expect(!viewModel.canLoadMoreEditorResults)

        _ = try await connection.execute("DROP TABLE \(table)", params: nil)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: testPort("LODE_TEST_PG_PORT") != nil))
    func postgresDefaultLimitAndLoadMore() async throws {
        let port = try #require(testPort("LODE_TEST_PG_PORT"))
        let (viewModel, manager) = await makeViewModel()
        let config = DatabaseConfig(
            name: "paging-it", type: .postgresql, host: "127.0.0.1", port: port,
            database: "testdb", username: "postgres", password: "test"
        )
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        let table = uniqueTable()

        _ = try await connection.execute("CREATE TABLE \(table) (id INT PRIMARY KEY)", params: nil)
        _ = try await connection.execute(
            "INSERT INTO \(table) (id) SELECT g FROM generate_series(1, 2500) AS g", params: nil
        )

        viewModel.queryText = "SELECT id FROM \(table) ORDER BY id"
        await viewModel.executeQuery()
        expectWindow(viewModel, rows: 1000, lastID: 1000)
        #expect(viewModel.editorHasMore)

        await viewModel.loadMoreEditorResults()
        expectWindow(viewModel, rows: 2000, lastID: 2000)

        await viewModel.loadMoreEditorResults()
        expectWindow(viewModel, rows: 2500, lastID: 2500)
        #expect(!viewModel.editorHasMore)

        _ = try await connection.execute("DROP TABLE \(table)", params: nil)
        await viewModel.disconnect()
    }
}