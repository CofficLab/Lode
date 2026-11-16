import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// 隧道装饰器驱动：透明改写 host/port、隧道生命周期绑定、掉线判定、失败清理。
/// 用 mock 引擎/驱动/连接验证编排逻辑，不依赖 libssh2。
struct SSHTunnelingTests {
    // MARK: - Mocks

    private final class MockTunnel: SSHTunnel, @unchecked Sendable {
        let localPort: Int
        private let lock = NSLock()
        private var _alive = true
        private var _closed = false
        init(localPort: Int) { self.localPort = localPort }
        var alive: Bool { lock.withLock { _alive } }
        var closed: Bool { lock.withLock { _closed } }
        func setAlive(_ value: Bool) { lock.withLock { _alive = value } }
        func isAlive() async -> Bool { alive }
        func close() async { lock.withLock { _closed = true; _alive = false } }
    }

    private final class MockEngine: SSHTunnelEngine, @unchecked Sendable {
        let tunnel: MockTunnel
        var error: Error?
        private let lock = NSLock()
        private var _calls: [(ssh: ConnectionSSHConfig, host: String, port: Int)] = []
        init(tunnel: MockTunnel) { self.tunnel = tunnel }
        var calls: [(ssh: ConnectionSSHConfig, host: String, port: Int)] { lock.withLock { _calls } }
        func openTunnel(ssh: ConnectionSSHConfig, targetHost: String, targetPort: Int) async throws -> any SSHTunnel {
            lock.withLock { _calls.append((ssh, targetHost, targetPort)) }
            if let error { throw error }
            return tunnel
        }
    }

    private final class MockConnection: DatabaseConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var _closed = false
        private var _alive = true
        private var _executed: [String] = []
        var closed: Bool { lock.withLock { _closed } }
        var alive: Bool { lock.withLock { _alive } }
        var executed: [String] { lock.withLock { _executed } }
        func setAlive(_ value: Bool) { lock.withLock { _alive = value } }
        func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
            lock.withLock { _executed.append(sql) }
            return 1
        }
        func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
            QueryResult(columns: ["c"], rows: [[.integer(1)]], rowsAffected: 0)
        }
        func beginTransaction() async throws -> any DatabaseTransaction {
            throw DatabaseError.notImplemented
        }
        func close() async { lock.withLock { _closed = true } }
        func isAlive() async -> Bool { alive }
        func cancel() async {}
    }

    private final class MockDriver: DatabaseDriver, @unchecked Sendable {
        let type: DatabaseType
        let connection: MockConnection
        var error: Error?
        private let lock = NSLock()
        private var _configs: [DatabaseConfig] = []
        init(type: DatabaseType, connection: MockConnection) {
            self.type = type
            self.connection = connection
        }
        var configs: [DatabaseConfig] { lock.withLock { _configs } }
        func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
            lock.withLock { _configs.append(config) }
            if let error { throw error }
            return connection
        }
    }

    private func sshConfig() -> ConnectionSSHConfig {
        ConnectionSSHConfig(host: "jump", username: "u", authMethod: .agent)
    }

    private func mysqlConfig(port: Int? = 3306) -> DatabaseConfig {
        DatabaseConfig(name: "db", type: .mysql, host: "db.internal", port: port, database: "testdb", username: "u")
    }

    // MARK: - 透传

    @Test("无 SSH 配置时原样透传，不建隧道")
    func noSSHPassthrough() async throws {
        let connection = MockConnection()
        let driver = MockDriver(type: .mysql, connection: connection)
        let engine = MockEngine(tunnel: MockTunnel(localPort: 40000))
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        let result = try await tunneling.connect(config: mysqlConfig())
        #expect(engine.calls.isEmpty)
        #expect(driver.configs.first?.host == "db.internal")
        #expect(!(result is TunneledConnection))
    }

    @Test("SQLite 忽略 SSH 配置")
    func sqliteIgnoresSSH() async throws {
        let connection = MockConnection()
        let driver = MockDriver(type: .sqlite, connection: connection)
        let engine = MockEngine(tunnel: MockTunnel(localPort: 40000))
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        var config = DatabaseConfig(name: "db", type: .sqlite, database: "/tmp/db.sqlite")
        config = config.withSSHConfig(sshConfig())
        _ = try await tunneling.connect(config: config)
        #expect(engine.calls.isEmpty)
    }

    // MARK: - 隧道建立与改写

    @Test("SSH 配置改写 host/port 为本地隧道端口")
    func rewritesHostPort() async throws {
        let connection = MockConnection()
        let driver = MockDriver(type: .mysql, connection: connection)
        let tunnel = MockTunnel(localPort: 40000)
        let engine = MockEngine(tunnel: tunnel)
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        let config = mysqlConfig().withSSHConfig(sshConfig())
        let result = try await tunneling.connect(config: config)
        #expect(engine.calls.count == 1)
        #expect(engine.calls.first?.host == "db.internal")
        #expect(engine.calls.first?.port == 3306)
        #expect(driver.configs.first?.host == "127.0.0.1")
        #expect(driver.configs.first?.port == 40000)
        #expect(result is TunneledConnection)
    }

    @Test("port 为 nil 时用引擎默认端口建隧道")
    func defaultTargetPort() async throws {
        let driver = MockDriver(type: .mysql, connection: MockConnection())
        let engine = MockEngine(tunnel: MockTunnel(localPort: 40000))
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        _ = try await tunneling.connect(config: mysqlConfig(port: nil).withSSHConfig(sshConfig()))
        #expect(engine.calls.first?.port == 3306)
    }

    @Test("非法 SSH 配置在建隧道前抛出")
    func invalidSSHThrowsEarly() async {
        let driver = MockDriver(type: .mysql, connection: MockConnection())
        let engine = MockEngine(tunnel: MockTunnel(localPort: 40000))
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        let bad = ConnectionSSHConfig(host: "", username: "u", authMethod: .agent)
        let config = mysqlConfig().withSSHConfig(bad)
        await #expect(throws: ConnectionSSHConfigError.missingHost) {
            _ = try await tunneling.connect(config: config)
        }
        #expect(engine.calls.isEmpty)
    }

    @Test("缺数据库 host 时抛 invalidConfiguration")
    func missingDatabaseHost() async {
        let driver = MockDriver(type: .mysql, connection: MockConnection())
        let engine = MockEngine(tunnel: MockTunnel(localPort: 40000))
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        var config = mysqlConfig()
        config.host = nil
        config = config.withSSHConfig(sshConfig())
        await #expect(throws: DatabaseError.self) {
            _ = try await tunneling.connect(config: config)
        }
        #expect(engine.calls.isEmpty)
    }

    // MARK: - 生命周期

    @Test("底层连接失败时关闭已建隧道")
    func closesTunnelOnConnectFailure() async {
        let driver = MockDriver(type: .mysql, connection: MockConnection())
        driver.error = DatabaseError.connectionFailed("boom")
        let tunnel = MockTunnel(localPort: 40000)
        let engine = MockEngine(tunnel: tunnel)
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        await #expect(throws: DatabaseError.self) {
            _ = try await tunneling.connect(config: mysqlConfig().withSSHConfig(sshConfig()))
        }
        #expect(tunnel.closed)
    }

    @Test("连接 close 同时关闭内层连接与隧道")
    func closeClosesBoth() async throws {
        let connection = MockConnection()
        let driver = MockDriver(type: .mysql, connection: connection)
        let tunnel = MockTunnel(localPort: 40000)
        let engine = MockEngine(tunnel: tunnel)
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        let result = try await tunneling.connect(config: mysqlConfig().withSSHConfig(sshConfig()))
        await result.close()
        #expect(connection.closed)
        #expect(tunnel.closed)
    }

    @Test("isAlive 要求隧道与内层连接均健康")
    func isAliveRequiresBoth() async throws {
        let connection = MockConnection()
        let driver = MockDriver(type: .mysql, connection: connection)
        let tunnel = MockTunnel(localPort: 40000)
        let engine = MockEngine(tunnel: tunnel)
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        let result = try await tunneling.connect(config: mysqlConfig().withSSHConfig(sshConfig()))
        #expect(await result.isAlive())
        tunnel.setAlive(false)
        #expect(await result.isAlive() == false)
        tunnel.setAlive(true)
        connection.setAlive(false)
        #expect(await result.isAlive() == false)
    }

    @Test("execute/query 透传给内层连接")
    func delegatesOperations() async throws {
        let connection = MockConnection()
        let driver = MockDriver(type: .mysql, connection: connection)
        let engine = MockEngine(tunnel: MockTunnel(localPort: 40000))
        let tunneling = TunnelingDriver(wrapped: driver, engine: engine)
        let result = try await tunneling.connect(config: mysqlConfig().withSSHConfig(sshConfig()))
        _ = try await result.execute("SELECT 1", params: nil)
        let query = try await result.query("SELECT 1", params: nil)
        #expect(connection.executed == ["SELECT 1"])
        #expect(query.columns == ["c"])
    }
}