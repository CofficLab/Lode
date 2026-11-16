@testable import DatabaseManagerPlugin
import Foundation
import Testing

// 连接池生命周期：池内空闲连接必须随连接生命周期一起关闭。
// 心跳经 withConnection 借出独立连接，归还后留在池内空闲；disconnect/重连若不排空池，
// 这些连接会随 manager 释放而未 close —— MySQLNIO 在 deinit 断言「not closed before deinit」并 trap。
// 用每次 connect 新建的间谍连接记录 close 次数，离线精确驱动「借出→归还→断开/重连」三路径。

private actor PoolSpyConnection: DatabaseConnection {
    private(set) var closeCount = 0
    private var alive = true

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        QueryResult(columns: ["n"], rows: [[.integer(1)]], rowsAffected: 0)
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 1 }
    func beginTransaction() async throws -> any DatabaseTransaction { PoolSpyTransaction() }
    func close() async {
        closeCount += 1
        alive = false
    }
    func isAlive() async -> Bool { alive }
    func cancel() async {}
}

private struct PoolSpyTransaction: DatabaseTransaction {
    func commit() async throws {}
    func rollback() async throws {}
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
}

private actor PoolSpyDriver: DatabaseDriver {
    nonisolated let type: DatabaseType = .mysql
    private(set) var created: [PoolSpyConnection] = []

    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        let connection = PoolSpyConnection()
        created.append(connection)
        return connection
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConnectionPoolLifecycleTests {
    private func makeSUT() async -> (DatabaseManagerCore, PoolSpyDriver) {
        let manager = DatabaseManagerCore()
        let driver = PoolSpyDriver()
        await manager.register(driver: driver)
        return (manager, driver)
    }

    private func makeConfig(database: String = "testdb") -> DatabaseConfig {
        DatabaseConfig(name: "pool", type: .mysql, host: "127.0.0.1", database: database, username: "u")
    }

    /// 借出一条池连接并归还（留在池内空闲），返回主连接与池连接。
    private func borrowPooledConnection(
        _ manager: DatabaseManagerCore,
        _ driver: PoolSpyDriver,
        config: DatabaseConfig
    ) async throws -> (main: PoolSpyConnection, pooled: PoolSpyConnection) {
        _ = try await manager.connect(config: config)
        try await manager.withConnection(for: config) { connection in
            _ = try await connection.query("SELECT 1", params: nil)
        }
        let created = await driver.created
        #expect(created.count == 2)
        return (created[0], created[1])
    }

    @Test func disconnectClosesPooledConnection() async throws {
        let (manager, driver) = await makeSUT()
        let config = makeConfig()
        let (main, pooled) = try await borrowPooledConnection(manager, driver, config: config)
        #expect(await pooled.closeCount == 0)

        await manager.disconnect(configId: config.id)

        #expect(await main.closeCount == 1)
        // 修复前池连接不随 disconnect 关闭（closeCount 0），随 manager 释放触发 MySQLNIO deinit 断言。
        #expect(await pooled.closeCount == 1)
    }

    @Test func disconnectAllClosesPooledConnections() async throws {
        let (manager, driver) = await makeSUT()
        let config = makeConfig()
        let (main, pooled) = try await borrowPooledConnection(manager, driver, config: config)

        await manager.disconnectAll()

        #expect(await main.closeCount == 1)
        #expect(await pooled.closeCount == 1)
    }

    @Test func reconnectDrainsStalePool() async throws {
        let (manager, driver) = await makeSUT()
        let config = makeConfig()
        let (main, pooled) = try await borrowPooledConnection(manager, driver, config: config)

        // 同 id 重连（switchDatabase 路径，仅改 database 保留 id）：旧主连接与旧池连接都应关闭。
        var updated = config
        updated.database = "other"
        _ = try await manager.connect(config: updated)

        #expect(await main.closeCount == 1)
        #expect(await pooled.closeCount == 1)
        let created = await driver.created
        #expect(created.count == 3)
        #expect(await created[2].closeCount == 0)
    }

    @Test func poolRebuildsAfterDisconnect() async throws {
        let (manager, driver) = await makeSUT()
        let config = makeConfig()
        _ = try await borrowPooledConnection(manager, driver, config: config)
        await manager.disconnect(configId: config.id)

        // 断开后重新连接并借池连接：池应已重建，借出的是全新连接而非已关闭的旧连接。
        _ = try await manager.connect(config: config)
        try await manager.withConnection(for: config) { connection in
            #expect(await connection.isAlive())
            _ = try await connection.query("SELECT 1", params: nil)
        }
        let created = await driver.created
        #expect(created.count == 4)
        #expect(await created[3].closeCount == 0)
    }
}