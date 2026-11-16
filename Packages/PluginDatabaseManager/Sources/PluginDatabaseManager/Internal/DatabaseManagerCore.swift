import Foundation

public actor DatabaseManagerCore {
    public static let shared = DatabaseManagerCore()

    private var drivers: [DatabaseType: any DatabaseDriver] = [:]
    private var activeConnections: [UUID: any DatabaseConnection] = [:]
    private var pools: [UUID: ConnectionPool] = [:]
    private var builtinsRegistered = false

    public init() {}

    /// 标记内置驱动已注册；仅首次返回 true。状态随 manager 实例存亡，
    /// 避免用全局 ObjectIdentifier 集合时地址复用导致新 manager 误判「已注册」。
    func markBuiltinsRegistered() -> Bool {
        if builtinsRegistered { return false }
        builtinsRegistered = true
        return true
    }

    public func register(driver: any DatabaseDriver) {
        drivers[driver.type] = driver
    }

    public func getDriver(for type: DatabaseType) throws -> any DatabaseDriver {
        guard let driver = drivers[type] else {
            throw DatabaseError.driverNotFound(type)
        }
        return driver
    }

    /// 某类型驱动声明的能力。驱动未注册时回退到 ``DatabaseType/capabilities`` 的内置 preset。
    public func capabilities(for type: DatabaseType) -> DatabaseCapabilities {
        (try? getDriver(for: type).capabilities) ?? type.capabilities
    }

    public func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        let driver = try getDriver(for: config.type)
        let raw = try await driver.connect(config: config)
        // 非 off 档套一层安全模式连接：readOnly 在驱动层硬拒绝写语句，
        // 覆盖 getConnection 的所有调用方（编辑器、变更队列、DDL、Agent）。
        let connection: any DatabaseConnection = config.safeMode == .off
            ? raw
            : SafeModeConnection(wrapped: raw, safeMode: config.safeMode, type: config.type)
        if let existingConnection = activeConnections[config.id] {
            await existingConnection.close()
        }
        activeConnections[config.id] = connection
        return connection
    }

    public func getConnection(for configId: UUID) -> (any DatabaseConnection)? {
        activeConnections[configId]
    }

    public func disconnect(configId: UUID) async {
        if let connection = activeConnections[configId] {
            await connection.close()
            activeConnections.removeValue(forKey: configId)
        }
    }

    public func disconnectAll() async {
        let connections = activeConnections.values
        activeConnections.removeAll()

        for connection in connections {
            await connection.close()
        }
    }

    public func getPool(for config: DatabaseConfig, maxConnections: Int = 5) throws -> ConnectionPool {
        if let pool = pools[config.id] {
            return pool
        }
        let driver = try getDriver(for: config.type)
        let pool = ConnectionPool(config: config, driver: driver, maxConnections: maxConnections)
        pools[config.id] = pool
        return pool
    }

    /// 从连接池借出一个连接。调用方用完必须调用 ``releaseConnection(_:for:)`` 归还。
    ///
    /// - Important: SQLite 的 `:memory:` 数据库是「每连接独立」的，池化借出的连接看不到
    ///   其它连接建立的内存表。对 `:memory:` 场景应改用单连接路径（``connect``/``getConnection``）。
    public func acquireConnection(for config: DatabaseConfig) async throws -> any DatabaseConnection {
        let pool = try getPool(for: config)
        return try await pool.acquire()
    }

    /// 归还由 ``acquireConnection(for:)`` 借出的连接。池已关闭时直接关闭连接。
    public func releaseConnection(_ connection: any DatabaseConnection, for config: DatabaseConfig) async {
        guard let pool = pools[config.id] else {
            await connection.close()
            return
        }
        await pool.release(connection)
    }

    /// 借出连接 → 执行闭包 → 归还（无论成功或抛错）。这是推荐的池使用方式。
    public func withConnection<T>(
        for config: DatabaseConfig,
        _ body: @Sendable (any DatabaseConnection) async throws -> T
    ) async throws -> T {
        let connection = try await acquireConnection(for: config)
        do {
            let result = try await body(connection)
            await releaseConnection(connection, for: config)
            return result
        } catch {
            await releaseConnection(connection, for: config)
            throw error
        }
    }

    public func shutdownPool(configId: UUID) async {
        guard let pool = pools.removeValue(forKey: configId) else {
            return
        }

        await pool.shutdown()
    }

    public func shutdownAllPools() async {
        let pools = pools.values
        self.pools.removeAll()

        for pool in pools {
            await pool.shutdown()
        }
    }

    public func probe(config: DatabaseConfig) async throws {
        let driver = try getDriver(for: config.type)
        let connection = try await driver.connect(config: config)
        await connection.close()
    }

    public func shutdown() async {
        await disconnectAll()
        await shutdownAllPools()
    }
}
