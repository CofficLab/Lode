import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P4-2 真实引擎验收：自签证书 PostgreSQL verify-full，Redis TLS + ACL + SELECT db。
// 需要本地 Docker TLS 容器（见 work/lode-tls-setup.sh，仓库外）：
//   - PostgreSQL TLS：LODE_TEST_PG_TLS_PORT（如 54322），postgres/test，testdb，
//     ssl=on，服务器证书 SAN 含 IP:127.0.0.1。
//   - Redis TLS+ACL：LODE_TEST_REDIS_TLS_PORT（如 63792），default|testuser / testpass。
//   - LODE_TEST_TLS_CA：签发服务器证书的 CA PEM 路径。
//   - LODE_TEST_TLS_WRONG_CA：无关 CA PEM 路径（用于拒绝用例）。
// 未设置相应环境变量时对应用例自动跳过。

private func pgTLSPort() -> Int? {
    ProcessInfo.processInfo.environment["LODE_TEST_PG_TLS_PORT"].flatMap(Int.init)
}

private func redisTLSPort() -> Int? {
    ProcessInfo.processInfo.environment["LODE_TEST_REDIS_TLS_PORT"].flatMap(Int.init)
}

private func tlsCAPath() -> String? {
    ProcessInfo.processInfo.environment["LODE_TEST_TLS_CA"]
}

private func tlsWrongCAPath() -> String? {
    ProcessInfo.processInfo.environment["LODE_TEST_TLS_WRONG_CA"]
}

private func tlsIntValue(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    default: return nil
    }
}

private func tlsStringValue(_ value: DatabaseValue?) -> String? {
    switch value {
    case .string(let s): return s
    case .integer(let i): return String(i)
    default: return nil
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct TLSIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func pgConfig(port: Int, mode: ConnectionSSLOption, ca: String?) -> DatabaseConfig {
        DatabaseConfig(name: "tls-pg", type: .postgresql, host: "127.0.0.1", port: port,
                       database: "testdb", username: "postgres", password: "test")
            .withSSLOption(mode)
            .withTLSConfig(ca.map { ConnectionTLSConfig(caCertPath: $0) })
    }

    private func redisConfig(port: Int, mode: ConnectionSSLOption, ca: String?,
                             username: String? = nil, database: String = "0") -> DatabaseConfig {
        DatabaseConfig(name: "tls-redis", type: .redis, host: "127.0.0.1", port: port,
                       database: database, username: username, password: "testpass")
            .withSSLOption(mode)
            .withTLSConfig(ca.map { ConnectionTLSConfig(caCertPath: $0) })
    }

    // MARK: - PostgreSQL

    @Test(.enabled(if: pgTLSPort() != nil && tlsCAPath() != nil))
    func pgVerifyFullSelfSigned() async throws {
        let port = try #require(pgTLSPort())
        let ca = try #require(tlsCAPath())
        let (viewModel, manager) = await makeSUT()
        let config = pgConfig(port: port, mode: .verifyFull, ca: ca)
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        #expect(tlsIntValue(try await connection.query("SELECT 1 AS one", params: nil)) == 1)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: pgTLSPort() != nil && tlsCAPath() != nil))
    func pgVerifyCA() async throws {
        let port = try #require(pgTLSPort())
        let ca = try #require(tlsCAPath())
        let (viewModel, manager) = await makeSUT()
        let config = pgConfig(port: port, mode: .verifyCA, ca: ca)
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        #expect(tlsIntValue(try await connection.query("SELECT 1 AS one", params: nil)) == 1)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: pgTLSPort() != nil))
    func pgRequireNoCA() async throws {
        let port = try #require(pgTLSPort())
        let (viewModel, manager) = await makeSUT()
        let config = pgConfig(port: port, mode: .require, ca: nil)
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        #expect(tlsIntValue(try await connection.query("SELECT 1 AS one", params: nil)) == 1)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: pgTLSPort() != nil && tlsWrongCAPath() != nil))
    func pgVerifyFullWrongCARejected() async throws {
        let port = try #require(pgTLSPort())
        let wrongCA = try #require(tlsWrongCAPath())
        let (viewModel, _) = await makeSUT()
        await #expect(throws: (any Error).self) {
            try await viewModel.testConnection(config: pgConfig(port: port, mode: .verifyFull, ca: wrongCA))
        }
    }

    // MARK: - Redis

    @Test(.enabled(if: redisTLSPort() != nil && tlsCAPath() != nil))
    func redisTLSDefaultUser() async throws {
        let port = try #require(redisTLSPort())
        let ca = try #require(tlsCAPath())
        let (viewModel, manager) = await makeSUT()
        let config = redisConfig(port: port, mode: .verifyFull, ca: ca)
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        _ = try await connection.execute("SET tls_default_k v1", params: nil)
        #expect(tlsStringValue(try await connection.query("GET tls_default_k", params: nil).rows.first?[1]) == "v1")
        await viewModel.disconnect()
    }

    @Test(.enabled(if: redisTLSPort() != nil && tlsCAPath() != nil))
    func redisTLSACLUser() async throws {
        let port = try #require(redisTLSPort())
        let ca = try #require(tlsCAPath())
        let (viewModel, manager) = await makeSUT()
        let config = redisConfig(port: port, mode: .verifyFull, ca: ca, username: "testuser")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        _ = try await connection.execute("SET tls_acl_k v2", params: nil)
        #expect(tlsStringValue(try await connection.query("GET tls_acl_k", params: nil).rows.first?[1]) == "v2")
        await viewModel.disconnect()
    }

    @Test(.enabled(if: redisTLSPort() != nil && tlsCAPath() != nil))
    func redisTLSSelectDBIsolation() async throws {
        let port = try #require(redisTLSPort())
        let ca = try #require(tlsCAPath())
        let (viewModel, manager) = await makeSUT()
        // 库 1 写入。
        let db1Config = redisConfig(port: port, mode: .verifyFull, ca: ca, database: "1")
        await viewModel.connect(config: db1Config)
        #expect(viewModel.isConnected)
        let db1 = try #require(await manager.getConnection(for: db1Config.id))
        _ = try await db1.execute("SET tls_db1_k isolated", params: nil)
        #expect(tlsStringValue(try await db1.query("GET tls_db1_k", params: nil).rows.first?[1]) == "isolated")
        await viewModel.disconnect()
        // 库 0 看不到库 1 的键。
        let db0Config = redisConfig(port: port, mode: .verifyFull, ca: ca, database: "0")
        await viewModel.connect(config: db0Config)
        #expect(viewModel.isConnected)
        let db0 = try #require(await manager.getConnection(for: db0Config.id))
        #expect(tlsIntValue(try await db0.query("EXISTS tls_db1_k", params: nil)) == 0)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: redisTLSPort() != nil && tlsWrongCAPath() != nil))
    func redisTLSWrongCARejected() async throws {
        let port = try #require(redisTLSPort())
        let wrongCA = try #require(tlsWrongCAPath())
        let (viewModel, _) = await makeSUT()
        await #expect(throws: (any Error).self) {
            try await viewModel.testConnection(config: redisConfig(port: port, mode: .verifyFull, ca: wrongCA))
        }
    }

    @Test(.enabled(if: redisTLSPort() != nil))
    func redisTLSRequireNoVerify() async throws {
        let port = try #require(redisTLSPort())
        let (viewModel, manager) = await makeSUT()
        let config = redisConfig(port: port, mode: .require, ca: nil)
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        _ = try await connection.execute("SET tls_require_k v3", params: nil)
        #expect(tlsStringValue(try await connection.query("GET tls_require_k", params: nil).rows.first?[1]) == "v3")
        await viewModel.disconnect()
    }
}