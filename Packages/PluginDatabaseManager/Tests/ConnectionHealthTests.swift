@testable import DatabaseManagerPlugin
import Foundation
import Testing

/// 连接健康与自动重连（P1-3）：心跳探测、断线一次重连并保留上下文、
/// 重连失败落回未连接态、查询断线重连重跑、无限循环防护、超时配置解析。
///
/// 用共享假连接模拟「服务器」：probeFailuresRemaining / queryFailuresRemaining
/// 控制前 N 次查询抛断线类错误，之后恢复，从而精确驱动「断流→恢复」两路径。
private actor HealthFakeConnection: DatabaseConnection {
    var probeFailuresRemaining = 0
    var queryFailuresRemaining = 0
    var queryError: (any Error)?
    private(set) var queries: [String] = []

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        queries.append(sql)
        if let queryError { throw queryError }
        let isProbe = sql == "SELECT 1" || sql == "PING"
        if isProbe && probeFailuresRemaining > 0 {
            probeFailuresRemaining -= 1
            throw DatabaseError.connectionFailed("MySQL server has gone away")
        }
        if queryFailuresRemaining > 0 {
            queryFailuresRemaining -= 1
            throw DatabaseError.connectionFailed("MySQL server has gone away")
        }
        return QueryResult(columns: ["n"], rows: [[.integer(1)]], rowsAffected: 0)
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 1 }
    func beginTransaction() async throws -> any DatabaseTransaction { HealthFakeTransaction() }
    func close() async {}
    func isAlive() async -> Bool { true }
    func cancel() async {}
}

private struct HealthFakeTransaction: DatabaseTransaction {
    func commit() async throws {}
    func rollback() async throws {}
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
}

private actor HealthFakeDriver: DatabaseDriver {
    nonisolated let type: DatabaseType
    var connectError: (any Error)?
    private(set) var connectCount = 0
    let connection: HealthFakeConnection

    init(type: DatabaseType = .mysql, connection: HealthFakeConnection) {
        self.type = type
        self.connection = connection
    }

    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        connectCount += 1
        if let connectError { throw connectError }
        return connection
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionHealthTests {
    private func makeSUT(type: DatabaseType = .mysql) async -> (DatabaseViewModel, HealthFakeDriver, HealthFakeConnection) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let connection = HealthFakeConnection()
        let driver = HealthFakeDriver(type: type, connection: connection)
        await manager.register(driver: driver)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, driver, connection)
    }

    private func makeConfig(type: DatabaseType = .mysql) -> DatabaseConfig {
        DatabaseConfig(name: "health", type: type, host: "127.0.0.1", database: "testdb", username: "u")
    }

    // MARK: - 心跳探测与重连

    @Test func heartbeatDetectsLossAndReconnectsPreservingContext() async {
        let (viewModel, _, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        #expect(viewModel.isConnected)
        #expect(viewModel.isHeartbeatActive)
        viewModel.queryText = "SELECT name FROM users"
        // 探测失败一次，随后恢复（模拟服务器短暂断流后回来）。
        await connection.setProbeFailures(1)

        await viewModel.checkConnectionHealth()

        #expect(viewModel.isConnected)
        #expect(viewModel.queryText == "SELECT name FROM users")
        #expect(viewModel.classifiedError == nil)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isHeartbeatActive)
        // 重连后查询可正常执行。
        await viewModel.executeQuery()
        #expect(viewModel.queryResult?.rows == [[.integer(1)]])
    }

    @Test func heartbeatReconnectFailureFallsBackToDisconnected() async {
        let (viewModel, driver, _) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        #expect(viewModel.isConnected)
        // 初始连接成功后再让后续 connect 失败：探测与重连都会失败。
        await driver.setConnectError(DatabaseError.connectionFailed("Connection refused"))

        await viewModel.checkConnectionHealth()

        #expect(viewModel.isConnected == false)
        #expect(viewModel.classifiedError?.category == .networkUnreachable)
        #expect(viewModel.classifiedError?.recovery == .retry)
        #expect(viewModel.isHeartbeatActive == false)
        #expect(viewModel.errorMessage?.contains("Connection refused") == true)
    }

    @Test func failedReconnectDoesNotLoop() async {
        let (viewModel, driver, _) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        await driver.setConnectError(DatabaseError.connectionFailed("Connection refused"))
        await viewModel.checkConnectionHealth()
        #expect(viewModel.isConnected == false)
        let countAfterFailure = await driver.connectCount

        // 再次心跳：未连接态直接返回，不会发起第二次自动重连。
        await viewModel.checkConnectionHealth()
        #expect(await driver.connectCount == countAfterFailure)
        #expect(viewModel.isConnected == false)
    }

    @Test func sqliteDoesNotStartHeartbeat() async {
        let (viewModel, _, _) = await makeSUT(type: .sqlite)
        await viewModel.connect(config: makeConfig(type: .sqlite))
        #expect(viewModel.isConnected)
        #expect(viewModel.isHeartbeatActive == false)
    }

    @Test func disconnectStopsHeartbeat() async {
        let (viewModel, _, _) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        #expect(viewModel.isHeartbeatActive)
        await viewModel.disconnect()
        #expect(viewModel.isHeartbeatActive == false)
        #expect(viewModel.isConnected == false)
    }

    // MARK: - 查询断线重连重跑

    @Test func queryConnectionLossReconnectsAndRetries() async {
        let (viewModel, driver, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        viewModel.queryText = "SELECT name FROM users"
        // 第一次查询断线，重连后恢复。
        await connection.setQueryFailures(1)

        await viewModel.executeQuery()

        #expect(viewModel.queryResult?.rows == [[.integer(1)]])
        #expect(viewModel.classifiedError == nil)
        #expect(viewModel.isConnected)
        // 初始连接 + 恰好一次自动重连（查询走主连接，不经连接池，计数干净）。
        #expect(await driver.connectCount == 2)
    }

    @Test func persistentQueryLossDoesNotLoop() async {
        let (viewModel, driver, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        viewModel.queryText = "SELECT name FROM users"
        await connection.setQueryFailures(100)

        await viewModel.executeQuery()

        #expect(viewModel.classifiedError?.category == .connectionLost)
        #expect(viewModel.queryResult == nil)
        // isRetry 防护：尽管持续断线，也只重连一次，不无限循环。
        #expect(await driver.connectCount == 2)
    }

    @Test func queryReconnectFailureSurfacesError() async {
        let (viewModel, driver, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        viewModel.queryText = "SELECT name FROM users"
        await connection.setQueryFailures(100)
        await driver.setConnectError(DatabaseError.connectionFailed("Connection refused"))

        await viewModel.executeQuery()

        #expect(viewModel.isConnected == false)
        #expect(viewModel.classifiedError != nil)
        #expect(viewModel.queryResult == nil)
        #expect(await driver.connectCount == 2)
    }

    @Test func retryAfterLossPreservesQueryText() async {
        let (viewModel, driver, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        viewModel.queryText = "SELECT name FROM users"
        // 断流且自动重连失败（服务器仍不可用）→ 落回未连接态。
        await connection.setProbeFailures(1)
        await driver.setConnectError(DatabaseError.connectionFailed("Connection refused"))
        await viewModel.checkConnectionHealth()
        #expect(viewModel.isConnected == false)

        // 服务器恢复后手动重试：重连必须保留编辑器文本，而不是重置成默认语句。
        await driver.setConnectError(nil)
        await viewModel.retryLastAction()

        #expect(viewModel.isConnected)
        #expect(viewModel.queryText == "SELECT name FROM users")
        await viewModel.executeQuery()
        #expect(viewModel.queryResult?.rows == [[.integer(1)]])
    }
}

// MARK: - 连接超时配置解析

@Suite
struct ConnectTimeoutConfigTests {
    private func config(options: [String: String]?) -> DatabaseConfig {
        DatabaseConfig(name: "t", type: .mysql, host: "127.0.0.1", database: "db", options: options)
    }

    @Test func defaultsToTenWhenAbsent() {
        #expect(config(options: nil).connectTimeoutSeconds == 10)
        #expect(config(options: [:]).connectTimeoutSeconds == 10)
    }

    @Test func parsesExplicitValue() {
        #expect(config(options: ["connectTimeoutSeconds": "5"]).connectTimeoutSeconds == 5)
        #expect(config(options: ["connectTimeoutSeconds": "30"]).connectTimeoutSeconds == 30)
    }

    @Test func zeroMeansUnlimited() {
        #expect(config(options: ["connectTimeoutSeconds": "0"]).connectTimeoutSeconds == 0)
    }

    @Test func negativeClampsToZero() {
        #expect(config(options: ["connectTimeoutSeconds": "-3"]).connectTimeoutSeconds == 0)
    }

    @Test func invalidFallsBackToDefault() {
        #expect(config(options: ["connectTimeoutSeconds": "abc"]).connectTimeoutSeconds == 10)
        #expect(config(options: ["connectTimeoutSeconds": ""]).connectTimeoutSeconds == 10)
    }
}

private extension HealthFakeDriver {
    func setConnectError(_ error: (any Error)?) {
        connectError = error
    }
}

private extension HealthFakeConnection {
    func setProbeFailures(_ count: Int) {
        probeFailuresRemaining = count
    }

    func setQueryFailures(_ count: Int) {
        queryFailuresRemaining = count
    }
}