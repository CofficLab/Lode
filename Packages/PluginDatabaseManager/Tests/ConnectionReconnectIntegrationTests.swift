import Foundation
import Testing
@testable import DatabaseManagerPlugin

// 需要本地 Docker 引擎：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT / LODE_TEST_REDIS_PORT 后启用。
// 验证真实断线重连：
// 1. 查询断线（KILL 主连接，服务器仍在）→ executeQuery 自动重连并重跑成功；
// 2. 容器停启（opt-in LODE_TEST_*_RESTART=1）→ 心跳探测失败给出可行动分类错误，手动重试后恢复。
//
// 容器停启会短暂影响共享引擎，故本套件串行执行，且仅在显式开启 RESTART 时运行停启用例。

private func testPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func restartEnabled(_ key: String) -> Bool {
    ProcessInfo.processInfo.environment[key] == "1"
}

private func intValue(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    default: return nil
    }
}

private func runDocker(_ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["docker"] + args
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "docker \(args.joined(separator: " ")) failed")
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ConnectionReconnectIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    // MARK: - 查询断线重连（服务器仍在，KILL 主连接）

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlQueryLossReconnectsAndRetries() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "rc", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        viewModel.queryText = "SELECT 1"

        let active = try #require(await manager.getConnection(for: config.id))
        let victimID = try #require(intValue(try await active.query("SELECT CONNECTION_ID()", params: nil)))
        let admin = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        _ = try await admin.execute("KILL \(victimID)", params: nil)
        await admin.close()

        await viewModel.executeQuery()
        #expect(viewModel.isConnected)
        #expect(viewModel.classifiedError == nil)
        #expect(viewModel.queryResult?.rows.first?.first == .integer(1))
        #expect(viewModel.queryText == "SELECT 1")
        await viewModel.disconnect()
    }

    @Test(.enabled(if: testPort("LODE_TEST_PG_PORT") != nil))
    func pgQueryLossReconnectsAndRetries() async throws {
        let port = try #require(testPort("LODE_TEST_PG_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "rc", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        viewModel.queryText = "SELECT 1"

        let active = try #require(await manager.getConnection(for: config.id))
        let pid = try #require(intValue(try await active.query("SELECT pg_backend_pid()", params: nil)))
        let admin = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        _ = try await admin.query("SELECT pg_terminate_backend(\(pid))", params: nil)
        await admin.close()
        // 服务端终止 backend 后异步关闭 TCP；稍候让客户端通道感知关闭，
        // 使下一次查询命中「连接已关闭」分支而非半开状态。
        try await Task.sleep(for: .seconds(1))

        await viewModel.executeQuery()
        #expect(viewModel.isConnected)
        #expect(viewModel.classifiedError == nil)
        #expect(viewModel.queryResult?.rows.first?.first == .integer(1))
        #expect(viewModel.queryText == "SELECT 1")
        await viewModel.disconnect()
    }

    @Test(.enabled(if: testPort("LODE_TEST_REDIS_PORT") != nil))
    func redisQueryLossReconnectsAndRetries() async throws {
        let port = try #require(testPort("LODE_TEST_REDIS_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "rc", type: .redis, host: "127.0.0.1", port: port, database: "0")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        viewModel.queryText = "PING"

        let active = try #require(await manager.getConnection(for: config.id))
        let clientID = try #require(intValue(try await active.query("CLIENT ID", params: nil)))
        let admin = try await RedisConnection(host: "127.0.0.1", port: port)
        _ = try await admin.execute("CLIENT KILL ID \(clientID)", params: nil)
        await admin.close()

        await viewModel.executeQuery()
        #expect(viewModel.isConnected)
        #expect(viewModel.classifiedError == nil)
        #expect(viewModel.queryResult != nil)
        #expect(viewModel.queryText == "PING")
        await viewModel.disconnect()
    }

    // MARK: - 容器停启：探测失败 → 分类错误 → 手动重试恢复（opt-in）

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil && restartEnabled("LODE_TEST_MYSQL_RESTART")))
    func mysqlContainerStopGivesActionableErrorThenRecovers() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        let (viewModel, _) = await makeSUT()
        let config = DatabaseConfig(name: "rc", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        viewModel.queryText = "SELECT 1"

        try runDocker(["stop", "lode-test-mysql"])
        await viewModel.checkConnectionHealth()
        #expect(viewModel.isConnected == false)
        #expect(viewModel.classifiedError != nil)
        #expect(viewModel.classifiedError?.recovery == .retry)

        try runDocker(["start", "lode-test-mysql"])
        try await waitMySQLReady(port: port)
        await viewModel.retryLastAction()
        #expect(viewModel.isConnected)
        #expect(viewModel.queryText == "SELECT 1")
        await viewModel.executeQuery()
        #expect(viewModel.queryResult?.rows.first?.first == .integer(1))
        await viewModel.disconnect()
    }

    @Test(.enabled(if: testPort("LODE_TEST_PG_PORT") != nil && restartEnabled("LODE_TEST_PG_RESTART")))
    func pgContainerStopGivesActionableErrorThenRecovers() async throws {
        let port = try #require(testPort("LODE_TEST_PG_PORT"))
        let (viewModel, _) = await makeSUT()
        let config = DatabaseConfig(name: "rc", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        viewModel.queryText = "SELECT 1"

        try runDocker(["stop", "lode-test-pg"])
        await viewModel.checkConnectionHealth()
        #expect(viewModel.isConnected == false)
        #expect(viewModel.classifiedError != nil)
        #expect(viewModel.classifiedError?.recovery == .retry)

        try runDocker(["start", "lode-test-pg"])
        try await waitPGReady(port: port)
        await viewModel.retryLastAction()
        #expect(viewModel.isConnected)
        #expect(viewModel.queryText == "SELECT 1")
        await viewModel.executeQuery()
        #expect(viewModel.queryResult?.rows.first?.first == .integer(1))
        await viewModel.disconnect()
    }

    @Test(.enabled(if: testPort("LODE_TEST_REDIS_PORT") != nil && restartEnabled("LODE_TEST_REDIS_RESTART")))
    func redisContainerStopGivesActionableErrorThenRecovers() async throws {
        let port = try #require(testPort("LODE_TEST_REDIS_PORT"))
        let (viewModel, _) = await makeSUT()
        let config = DatabaseConfig(name: "rc", type: .redis, host: "127.0.0.1", port: port, database: "0")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        viewModel.queryText = "PING"

        try runDocker(["stop", "lode-test-redis"])
        await viewModel.checkConnectionHealth()
        #expect(viewModel.isConnected == false)
        #expect(viewModel.classifiedError != nil)
        #expect(viewModel.classifiedError?.recovery == .retry)

        try runDocker(["start", "lode-test-redis"])
        try await waitRedisReady(port: port)
        await viewModel.retryLastAction()
        #expect(viewModel.isConnected)
        #expect(viewModel.queryText == "PING")
        await viewModel.disconnect()
    }

    // MARK: - 就绪轮询

    private func waitMySQLReady(port: Int, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
                await conn.close()
                return
            } catch {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        Issue.record("MySQL did not become ready within \(timeout)s")
    }

    private func waitPGReady(port: Int, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let conn = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
                await conn.close()
                return
            } catch {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        Issue.record("PostgreSQL did not become ready within \(timeout)s")
    }

    private func waitRedisReady(port: Int, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let conn = try await RedisConnection(host: "127.0.0.1", port: port)
                await conn.close()
                return
            } catch {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        Issue.record("Redis did not become ready within \(timeout)s")
    }
}