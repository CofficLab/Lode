import Foundation
import Testing
@testable import DatabaseManagerPlugin

// 连接池直测：直接驱动 ConnectionPool actor 的 acquire/release/shutdown 语义。
// ConnectionPoolLifecycleTests 走 DatabaseManagerCore 全链路，这里补齐 actor 自身的
// 等待队列、坏连接淘汰、外部连接归还、关闭时序等分支，全部离线。

private actor PoolDirectSpyConnection: DatabaseConnection {
    private(set) var closeCount = 0
    private var alive = true

    func kill() { alive = false }

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        QueryResult(columns: ["n"], rows: [[.integer(1)]], rowsAffected: 0)
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 1 }
    func beginTransaction() async throws -> any DatabaseTransaction { PoolDirectSpyTransaction() }
    func close() async {
        closeCount += 1
        alive = false
    }
    func isAlive() async -> Bool { alive }
    func cancel() async {}
}

private struct PoolDirectSpyTransaction: DatabaseTransaction {
    func commit() async throws {}
    func rollback() async throws {}
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
}

private actor PoolDirectSpyDriver: DatabaseDriver {
    nonisolated let type: DatabaseType = .mysql
    private(set) var created: [PoolDirectSpyConnection] = []
    private var pendingFailures: Int

    init(failedConnects: Int = 0) {
        pendingFailures = failedConnects
    }

    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        if pendingFailures > 0 {
            pendingFailures -= 1
            throw DatabaseError.connectionFailed("connect failed")
        }
        let connection = PoolDirectSpyConnection()
        created.append(connection)
        return connection
    }

    func killAll() async {
        for connection in created { await connection.kill() }
    }

    var createdCount: Int { created.count }
}

@Suite(.timeLimit(.minutes(1)))
struct ConnectionPoolDirectTests {
    private struct UnexpectedSpyType: Error {}

    /// 需要断言 closeCount 时取回具体 spy 类型。
    private func acquireSpy(_ pool: ConnectionPool) async throws -> PoolDirectSpyConnection {
        guard let spy = try await pool.acquire() as? PoolDirectSpyConnection else {
            throw UnexpectedSpyType()
        }
        return spy
    }

    private func makeConfig() -> DatabaseConfig {
        DatabaseConfig(name: "pool", type: .mysql, host: "127.0.0.1", database: "db", username: "u")
    }

    @Test("acquire 经 driver 创建新连接")
    func acquireCreatesViaDriver() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver)
        let connection = try await pool.acquire()
        #expect(await driver.createdCount == 1)
        #expect(await connection.isAlive())
    }

    @Test("归还将连接停入空闲位，再次 acquire 复用同一条")
    func acquireReusesIdleConnection() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver)
        let first = try await pool.acquire()
        await pool.release(first)
        let second = try await pool.acquire()
        #expect(ObjectIdentifier(second) == ObjectIdentifier(first))
        #expect(await driver.createdCount == 1)
    }

    @Test("空闲连接失活后被淘汰并新建")
    func deadIdleConnectionIsEvictedOnAcquire() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver)
        let first = try await acquireSpy(pool)
        await pool.release(first)
        await driver.killAll()
        let second = try await pool.acquire()
        #expect(ObjectIdentifier(second) != ObjectIdentifier(first))
        #expect(await driver.createdCount == 2)
        #expect(await first.closeCount == 1)
        #expect(await second.isAlive())
    }

    @Test("池满时等待者拿到归还的连接，不再新建")
    func waiterReceivesReleasedConnection() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver, maxConnections: 1)
        let first = try await pool.acquire()
        let waiter = Task { try await pool.acquire() }
        await pool.release(first)
        let second = try await waiter.value
        #expect(ObjectIdentifier(second) == ObjectIdentifier(first))
        #expect(await driver.createdCount == 1)
    }

    @Test("死连接归还给等待者时触发重连")
    func deadConnectionReleaseTriggersWaiterReconnect() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver, maxConnections: 1)
        let first = try await acquireSpy(pool)
        let waiter = Task { try await pool.acquire() }
        await driver.killAll()
        await pool.release(first)
        let second = try await waiter.value
        #expect(ObjectIdentifier(second) != ObjectIdentifier(first))
        #expect(await driver.createdCount == 2)
        #expect(await first.closeCount == 1)
        #expect(await second.isAlive())
    }

    @Test("归还非池管理的连接直接关闭")
    func foreignConnectionClosedOnRelease() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver)
        let foreign = PoolDirectSpyConnection()
        await pool.release(foreign)
        #expect(await foreign.closeCount == 1)
        #expect(await driver.createdCount == 0)
    }

    @Test("重复归还已空闲的连接是空操作")
    func doubleReleaseIsNoop() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver)
        let connection = try await acquireSpy(pool)
        await pool.release(connection)
        await pool.release(connection)
        #expect(await connection.closeCount == 0)
        let again = try await pool.acquire()
        #expect(ObjectIdentifier(again) == ObjectIdentifier(connection))
        #expect(await driver.createdCount == 1)
    }

    @Test("connect 失败不占用池名额，重试可建连")
    func failedConnectDoesNotLeakSlot() async throws {
        let driver = PoolDirectSpyDriver(failedConnects: 1)
        let pool = ConnectionPool(config: makeConfig(), driver: driver, maxConnections: 1)
        await #expect(throws: DatabaseError.self) { try await pool.acquire() }
        let connection = try await pool.acquire()
        #expect(await driver.createdCount == 1)
        #expect(await connection.isAlive())
    }

    @Test("shutdown 失败等待者并关闭空闲连接")
    func shutdownFailsWaitersAndClosesIdle() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver, maxConnections: 1)
        let idle = try await acquireSpy(pool)
        await pool.release(idle)
        let waiter = Task { try await pool.acquire() }
        await pool.shutdown()
        await #expect(throws: DatabaseError.self) { try await waiter.value }
        #expect(await idle.closeCount == 1)
        #expect(await idle.isAlive() == false)
    }

    @Test("shutdown 后归还借出中的连接会被直接关闭")
    func releaseAfterShutdownCloses() async throws {
        let driver = PoolDirectSpyDriver()
        let pool = ConnectionPool(config: makeConfig(), driver: driver)
        let held = try await acquireSpy(pool)
        await pool.shutdown()
        #expect(await held.closeCount == 0)
        await pool.release(held)
        #expect(await held.closeCount == 1)
    }

    @Test("shutdown 后 acquire 抛连接失败")
    func acquireAfterShutdownThrows() async {
        let pool = ConnectionPool(config: makeConfig(), driver: PoolDirectSpyDriver())
        await pool.shutdown()
        await #expect(throws: DatabaseError.self) { try await pool.acquire() }
    }
}
