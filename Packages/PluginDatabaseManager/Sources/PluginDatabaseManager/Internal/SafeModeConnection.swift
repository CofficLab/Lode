import Foundation

/// 连接级安全模式的驱动层硬保证。
///
/// readOnly 连接拒绝任何写语句，覆盖 ``DatabaseConnection/execute(_:params:)``、
/// ``DatabaseConnection/query(_:params:)`` 与事务 ``DatabaseTransaction/execute(_:params:)``
/// 三条入口——即使 VM 闸门被绕过（Agent、池借出、直接调用），写仍被拦下。
/// confirmWrites / off 档原样透传（确认是 VM/UI 职责，不在驱动层弹窗）。
///
/// 所有存储属性均为不可变 Sendable，转发皆为 async，无共享可变状态，故 `@unchecked Sendable` 安全。
final class SafeModeConnection: DatabaseConnection, @unchecked Sendable {
    private let wrapped: any DatabaseConnection
    private let safeMode: ConnectionSafeMode
    private let type: DatabaseType

    init(wrapped: any DatabaseConnection, safeMode: ConnectionSafeMode, type: DatabaseType) {
        self.wrapped = wrapped
        self.safeMode = safeMode
        self.type = type
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        try guardWrite(sql)
        return try await wrapped.execute(sql, params: params)
    }

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        try guardWrite(sql)
        return try await wrapped.query(sql, params: params)
    }

    func beginTransaction() async throws -> any DatabaseTransaction {
        let transaction = try await wrapped.beginTransaction()
        guard safeMode == .readOnly else { return transaction }
        return SafeModeTransaction(wrapped: transaction, type: type)
    }

    func close() async { await wrapped.close() }
    func isAlive() async -> Bool { await wrapped.isAlive() }
    func cancel() async { await wrapped.cancel() }

    private func guardWrite(_ sql: String) throws {
        guard safeMode == .readOnly, WriteGate.isWriteStatement(sql, type: type) else { return }
        throw DatabaseError.queryFailed("Connection is read-only; write statements are blocked")
    }
}

/// SCAN 游标转发：读命令，无需写闸门；内层非 Redis 时不支持。
extension SafeModeConnection: RedisCursorScanning {
    func scanKeys(cursor: String, match: String?, count: Int) async throws -> (nextCursor: String, keys: [String]) {
        guard let inner = wrapped as? RedisCursorScanning else {
            throw DatabaseError.queryFailed("Underlying connection does not support Redis SCAN")
        }
        return try await inner.scanKeys(cursor: cursor, match: match, count: count)
    }
}

/// readOnly 连接的事务包装：事务内写语句同样被拒绝，commit/rollback 透传。
final class SafeModeTransaction: DatabaseTransaction, @unchecked Sendable {
    private let wrapped: any DatabaseTransaction
    private let type: DatabaseType

    init(wrapped: any DatabaseTransaction, type: DatabaseType) {
        self.wrapped = wrapped
        self.type = type
    }

    func commit() async throws { try await wrapped.commit() }
    func rollback() async throws { try await wrapped.rollback() }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        if WriteGate.isWriteStatement(sql, type: type) {
            throw DatabaseError.queryFailed("Connection is read-only; write statements are blocked")
        }
        return try await wrapped.execute(sql, params: params)
    }
}