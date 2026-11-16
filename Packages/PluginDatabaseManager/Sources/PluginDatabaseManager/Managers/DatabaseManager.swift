import Foundation

public enum DatabaseDriverBootstrap {
    public static func registerBuiltinsIfNeeded(on manager: DatabaseManagerCore = .shared) async {
        guard await manager.markBuiltinsRegistered() else { return }
        await manager.register(driver: SQLiteDriver())
        await manager.register(driver: MySQLDriver())
        await manager.register(driver: PostgreSQLDriver())
        await manager.register(driver: RedisDriver())
    }
}
