import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P4-1 真实引擎验收：经 SSH 跳板隧道连接 MySQL/PostgreSQL/Redis。
// 需要本地 Docker：
//   - 跳板机（openssh，允许 TcpForwarding）：LODE_TEST_SSH_PORT（如 2222），
//     用户 testuser/testpass；跳板机须能访问数据库引擎。
//   - 数据库引擎：LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT / LODE_TEST_REDIS_PORT。
//   - LODE_TEST_SSH_TARGET_HOST：数据库相对跳板机的地址，默认 host.docker.internal
//     （OrbStack/Docker Desktop 下指向宿主机，引擎端口映射在宿主机上）。
// 未设置相应环境变量时对应用例自动跳过。SQLite 忽略 SSH 的用例无需 Docker，始终运行。

private func sshTestPort() -> Int? {
    ProcessInfo.processInfo.environment["LODE_TEST_SSH_PORT"].flatMap(Int.init)
}

private func sshEnginePort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func sshTargetHost() -> String {
    ProcessInfo.processInfo.environment["LODE_TEST_SSH_TARGET_HOST"] ?? "host.docker.internal"
}

private func sshIntValue(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    default: return nil
    }
}

private func sshStringValue(_ value: DatabaseValue?) -> String? {
    switch value {
    case .string(let s): return s
    case .integer(let i): return String(i)
    default: return nil
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct SSHTunnelIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func tempKnownHosts() -> String {
        NSTemporaryDirectory() + "lode-ssh-known-\(UUID().uuidString).hosts"
    }

    private func sshConfig(knownHostsPath: String, password: String = "testpass") -> ConnectionSSHConfig {
        ConnectionSSHConfig(
            host: "127.0.0.1",
            port: sshTestPort() ?? 22,
            username: "testuser",
            authMethod: .password,
            password: password,
            knownHostsPath: knownHostsPath
        )
    }

    @Test(.enabled(if: sshTestPort() != nil && sshEnginePort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlThroughTunnel() async throws {
        let port = try #require(sshEnginePort("LODE_TEST_MYSQL_PORT"))
        let knownHosts = tempKnownHosts()
        defer { try? FileManager.default.removeItem(atPath: knownHosts) }
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "ssh-mysql", type: .mysql, host: sshTargetHost(), port: port,
                                    database: "testdb", username: "root", password: "test")
            .withSSHConfig(sshConfig(knownHostsPath: knownHosts))
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        #expect(await connection.isAlive())
        let result = try await connection.query("SELECT 1", params: nil)
        #expect(sshIntValue(result) == 1)
        await viewModel.disconnect()
        // 首次接触应已记录跳板机主机密钥。
        #expect(FileManager.default.fileExists(atPath: knownHosts))
    }

    @Test(.enabled(if: sshTestPort() != nil && sshEnginePort("LODE_TEST_PG_PORT") != nil))
    func pgThroughTunnel() async throws {
        let port = try #require(sshEnginePort("LODE_TEST_PG_PORT"))
        let knownHosts = tempKnownHosts()
        defer { try? FileManager.default.removeItem(atPath: knownHosts) }
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "ssh-pg", type: .postgresql, host: sshTargetHost(), port: port,
                                    database: "testdb", username: "postgres", password: "test")
            .withSSHConfig(sshConfig(knownHostsPath: knownHosts))
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        let result = try await connection.query("SELECT 1", params: nil)
        #expect(sshIntValue(result) == 1)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: sshTestPort() != nil && sshEnginePort("LODE_TEST_REDIS_PORT") != nil))
    func redisThroughTunnel() async throws {
        let port = try #require(sshEnginePort("LODE_TEST_REDIS_PORT"))
        let knownHosts = tempKnownHosts()
        defer { try? FileManager.default.removeItem(atPath: knownHosts) }
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "ssh-redis", type: .redis, host: sshTargetHost(), port: port, database: "0")
            .withSSHConfig(sshConfig(knownHostsPath: knownHosts))
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        _ = try await connection.execute("SET lode_ssh_tunnel_k v1", params: nil)
        let result = try await connection.query("GET lode_ssh_tunnel_k", params: nil)
        // GET 返回 ["Key", "Value"] 两列，值在第 1 列。
        #expect(sshStringValue(result.rows.first?[1]) == "v1")
        _ = try await connection.execute("DEL lode_ssh_tunnel_k", params: nil)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: sshTestPort() != nil && sshEnginePort("LODE_TEST_MYSQL_PORT") != nil))
    func hostKeyMismatchRejected() async throws {
        let port = try #require(sshEnginePort("LODE_TEST_MYSQL_PORT"))
        let knownHosts = tempKnownHosts()
        defer { try? FileManager.default.removeItem(atPath: knownHosts) }
        let (viewModel, _) = await makeSUT()
        let config = DatabaseConfig(name: "ssh-mitm", type: .mysql, host: sshTargetHost(), port: port,
                                    database: "testdb", username: "root", password: "test")
            .withSSHConfig(sshConfig(knownHostsPath: knownHosts))

        // 首次接触：TOFU 记录真实主机密钥。
        try await viewModel.testConnection(config: config)
        let recorded = try String(contentsOfFile: knownHosts, encoding: .utf8)
        // 篡改密钥（模拟中间人）：ed25519 base64 以 "AAAA" 开头。
        let tampered = recorded.replacingOccurrences(of: "AAAA", with: "BBBB", range: recorded.range(of: "AAAA"))
        #expect(tampered != recorded)
        try tampered.write(toFile: knownHosts, atomically: true, encoding: .utf8)

        // 再次连接：主机密钥不匹配必须被拒绝。
        do {
            try await viewModel.testConnection(config: config)
            Issue.record("Expected host key mismatch to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("SSH host key rejected"))
        }
    }

    @Test(.enabled(if: sshTestPort() != nil))
    func wrongPasswordRejected() async throws {
        let knownHosts = tempKnownHosts()
        defer { try? FileManager.default.removeItem(atPath: knownHosts) }
        let (viewModel, _) = await makeSUT()
        // 目标地址无需可达：认证在转发建立之前失败。
        let config = DatabaseConfig(name: "ssh-badauth", type: .mysql, host: sshTargetHost(), port: 3306,
                                    database: "testdb", username: "root", password: "test")
            .withSSHConfig(sshConfig(knownHostsPath: knownHosts, password: "definitely-wrong"))
        do {
            try await viewModel.testConnection(config: config)
            Issue.record("Expected wrong SSH password to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("SSH authentication failed"))
        }
    }

    @Test func sqliteIgnoresSSH() async throws {
        // SQLite 是本地文件：即使配置了 SSH 也应直接连接，不建立隧道。
        let path = NSTemporaryDirectory() + "lode-ssh-sqlite-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "ssh-sqlite", type: .sqlite, database: path)
            .withSSHConfig(ConnectionSSHConfig(host: "127.0.0.1", port: 22, username: "nobody",
                                               authMethod: .password, password: "unused"))
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        _ = try await connection.execute("CREATE TABLE t (v INTEGER)", params: nil)
        _ = try await connection.execute("INSERT INTO t (v) VALUES (7)", params: nil)
        #expect(sshIntValue(try await connection.query("SELECT v FROM t", params: nil)) == 7)
        await viewModel.disconnect()
    }
}