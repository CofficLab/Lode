import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P1-5 真实引擎验收：多语句脚本中故意放一条错误，两种批量策略行为符合选择。
// 网络引擎需本地 Docker：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT / LODE_TEST_REDIS_PORT 后启用。
// SQLite 用临时文件库，无需 Docker，始终运行。
//
// 脚本：INSERT 成功 → INSERT 不存在的表（必错）→ INSERT 成功。
// - 逐句继续：首尾两条落库（COUNT=2），中间失败；
// - 包裹事务：整体回滚（COUNT=0），失败后停止。

private func batchTestPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func batchIntValue(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    default: return nil
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct BatchTransactionIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    /// 在给定连接上跑「含错脚本 × 两种策略」，返回是否全部断言通过所需的计数。
    private func runSQLBatchScenario(connection: any DatabaseConnection, viewModel: DatabaseViewModel) async throws {
        _ = try await connection.execute("DROP TABLE IF EXISTS batch_t", params: nil)
        _ = try await connection.execute("CREATE TABLE batch_t (v INTEGER)", params: nil)
        let script = "INSERT INTO batch_t (v) VALUES (1); INSERT INTO no_such_table_xyz (v) VALUES (2); INSERT INTO batch_t (v) VALUES (3);"

        // 逐句继续：首尾落库。
        viewModel.queryText = script
        viewModel.batchPolicy = .continueOnError
        await viewModel.executeAllStatements()
        #expect(viewModel.multiExecutions.count == 3)
        #expect(viewModel.multiExecutions[0].succeeded)
        #expect(viewModel.multiExecutions[1].succeeded == false)
        #expect(viewModel.multiExecutions[2].succeeded)
        #expect(viewModel.lastBatchRolledBack == false)
        let continueCount = batchIntValue(try await connection.query("SELECT COUNT(*) FROM batch_t", params: nil))
        #expect(continueCount == 2)

        // 包裹事务：清空后重跑，整体回滚。
        _ = try await connection.execute("DELETE FROM batch_t", params: nil)
        viewModel.batchPolicy = .wrapInTransaction
        await viewModel.executeAllStatements()
        #expect(viewModel.lastBatchRolledBack)
        #expect(viewModel.multiExecutions.count == 2)
        #expect(viewModel.multiExecutions[1].succeeded == false)
        let wrapCount = batchIntValue(try await connection.query("SELECT COUNT(*) FROM batch_t", params: nil))
        #expect(wrapCount == 0)

        // 包裹事务全成功路径：提交后落库。
        _ = try await connection.execute("DELETE FROM batch_t", params: nil)
        viewModel.queryText = "INSERT INTO batch_t (v) VALUES (10); INSERT INTO batch_t (v) VALUES (20);"
        await viewModel.executeAllStatements()
        #expect(viewModel.lastBatchRolledBack == false)
        #expect(viewModel.multiExecutions.count == 2)
        let commitCount = batchIntValue(try await connection.query("SELECT COUNT(*) FROM batch_t", params: nil))
        #expect(commitCount == 2)

        _ = try await connection.execute("DROP TABLE IF EXISTS batch_t", params: nil)
    }

    @Test(.enabled(if: batchTestPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlBatchPolicies() async throws {
        let port = try #require(batchTestPort("LODE_TEST_MYSQL_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "batch", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runSQLBatchScenario(connection: connection, viewModel: viewModel)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: batchTestPort("LODE_TEST_PG_PORT") != nil))
    func pgBatchPolicies() async throws {
        let port = try #require(batchTestPort("LODE_TEST_PG_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "batch", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runSQLBatchScenario(connection: connection, viewModel: viewModel)
        await viewModel.disconnect()
    }

    @Test func sqliteBatchPolicies() async throws {
        let (viewModel, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-batch-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "batch", type: .sqlite, database: path)
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runSQLBatchScenario(connection: connection, viewModel: viewModel)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: batchTestPort("LODE_TEST_REDIS_PORT") != nil))
    func redisBatchPolicies() async throws {
        let port = try #require(batchTestPort("LODE_TEST_REDIS_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "batch", type: .redis, host: "127.0.0.1", port: port, database: "0")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        _ = try await connection.execute("DEL batch_k1 batch_k2 batch_k3", params: nil)

        // 逐句继续：首尾 SET 落库，中间未知命令失败。
        viewModel.queryText = "SET batch_k1 1; NOTACOMMAND xyz; SET batch_k3 3"
        viewModel.batchPolicy = .continueOnError
        await viewModel.executeAllStatements()
        #expect(viewModel.multiExecutions.count == 3)
        #expect(viewModel.multiExecutions[1].succeeded == false)
        #expect(batchIntValue(try await connection.query("EXISTS batch_k1", params: nil)) == 1)
        #expect(batchIntValue(try await connection.query("EXISTS batch_k3", params: nil)) == 1)

        // 包裹事务（MULTI）全成功：EXEC 后落库。
        _ = try await connection.execute("DEL batch_k1 batch_k2 batch_k3", params: nil)
        viewModel.queryText = "SET batch_k1 1; SET batch_k2 2"
        viewModel.batchPolicy = .wrapInTransaction
        await viewModel.executeAllStatements()
        #expect(viewModel.lastBatchRolledBack == false)
        #expect(batchIntValue(try await connection.query("EXISTS batch_k1", params: nil)) == 1)
        #expect(batchIntValue(try await connection.query("EXISTS batch_k2", params: nil)) == 1)

        // 包裹事务（MULTI）含错：队列期报错 → DISCARD，先前入队的 SET 不落库。
        _ = try await connection.execute("DEL batch_k1 batch_k2 batch_k3", params: nil)
        viewModel.queryText = "SET batch_k1 1; NOTACOMMAND xyz; SET batch_k3 3"
        await viewModel.executeAllStatements()
        #expect(viewModel.lastBatchRolledBack)
        #expect(batchIntValue(try await connection.query("EXISTS batch_k1", params: nil)) == 0)
        #expect(batchIntValue(try await connection.query("EXISTS batch_k3", params: nil)) == 0)

        _ = try await connection.execute("DEL batch_k1 batch_k2 batch_k3", params: nil)
        await viewModel.disconnect()
    }
}