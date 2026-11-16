import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P4-6 真实引擎验收：连接级 startup SQL。
// - 失败不阻塞连接（isConnected 仍为 true）但可见（startupSQLNotice 非空，可关闭）；
// - 成功执行会话引导脚本（建表/SET），多语句逐条跑通，无提示；
// - Redis 按换行逐条命令执行。
//
// 需本地 Docker：设置 LODE_TEST_PG_PORT / LODE_TEST_REDIS_PORT 后启用。
// 每个用例建独立随机命名的表/键，结束清理。

private func stPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func stText(_ result: QueryResult, _ row: Int = 0, _ col: Int = 0) -> String {
    guard row < result.rows.count, col < result.rows[row].count else { return "" }
    let value = result.rows[row][col]
    if case .string(let s) = value { return s }
    return value.description
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct StartupSQLIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func pgConfig(port: Int) -> DatabaseConfig {
        DatabaseConfig(name: "st", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
    }

    // MARK: - PostgreSQL

    @Test(.enabled(if: stPort("LODE_TEST_PG_PORT") != nil))
    func pgStartupFailureIsNonBlockingButVisible() async throws {
        let port = try #require(stPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        // 除零错误：startup 脚本失败，但连接本身已成功。
        let config = pgConfig(port: port).withStartupSQL("SELECT 1/0")
        await vm.connect(config: config)
        defer { Task { await vm.disconnect() } }
        #expect(vm.isConnected)
        #expect(vm.startupSQLNotice != nil)
        // 提示可关闭，且不影响连接状态。
        vm.dismissStartupSQLNotice()
        #expect(vm.startupSQLNotice == nil)
        #expect(vm.isConnected)
    }

    @Test(.enabled(if: stPort("LODE_TEST_PG_PORT") != nil))
    func pgStartupSuccessCreatesTableAndNoNotice() async throws {
        let port = try #require(stPort("LODE_TEST_PG_PORT"))
        let table = "p46_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, manager) = await makeSUT()
        let config = pgConfig(port: port).withStartupSQL("CREATE TABLE \(table) (id integer)")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        #expect(vm.startupSQLNotice == nil)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP TABLE IF EXISTS \(table)", params: nil); await vm.disconnect() } }
        // startup 脚本确实建了表。
        let result = try await conn.query("SELECT * FROM \(table)", params: nil)
        #expect(result.columns == ["id"])
    }

    @Test(.enabled(if: stPort("LODE_TEST_PG_PORT") != nil))
    func pgStartupMultiStatementRunsAll() async throws {
        let port = try #require(stPort("LODE_TEST_PG_PORT"))
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let a = "p46a_\(suffix)"
        let b = "p46b_\(suffix)"
        let (vm, manager) = await makeSUT()
        let config = pgConfig(port: port).withStartupSQL("CREATE TABLE \(a) (id integer); CREATE TABLE \(b) (id integer);")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        #expect(vm.startupSQLNotice == nil)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task {
            _ = try? await conn.execute("DROP TABLE IF EXISTS \(a)", params: nil)
            _ = try? await conn.execute("DROP TABLE IF EXISTS \(b)", params: nil)
            await vm.disconnect()
        } }
        let ra = try await conn.query("SELECT * FROM \(a)", params: nil)
        let rb = try await conn.query("SELECT * FROM \(b)", params: nil)
        #expect(ra.columns == ["id"])
        #expect(rb.columns == ["id"])
    }

    @Test(.enabled(if: stPort("LODE_TEST_PG_PORT") != nil))
    func pgNoStartupSQLLeavesNoticeNil() async throws {
        let port = try #require(stPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        await vm.connect(config: pgConfig(port: port))
        defer { Task { await vm.disconnect() } }
        #expect(vm.isConnected)
        #expect(vm.startupSQLNotice == nil)
    }

    // MARK: - Redis（按换行逐条命令）

    @Test(.enabled(if: stPort("LODE_TEST_REDIS_PORT") != nil))
    func redisStartupRunsCommandsPerLine() async throws {
        let port = try #require(stPort("LODE_TEST_REDIS_PORT"))
        let key = "p46:\(UUID().uuidString.prefix(8))"
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "st", type: .redis, host: "127.0.0.1", port: port, database: "0")
            .withStartupSQL("SET \(key) hello")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        #expect(vm.startupSQLNotice == nil)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DEL \(key)", params: nil); await vm.disconnect() } }
        let result = try await conn.query("GET \(key)", params: nil)
        #expect(stText(result, 0, 1) == "hello")
    }
}