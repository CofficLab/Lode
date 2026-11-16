import Foundation

public enum DatabaseDriverBootstrap {
    public static func registerBuiltinsIfNeeded(on manager: DatabaseManagerCore = .shared) async {
        guard await manager.markBuiltinsRegistered() else { return }
        await manager.register(driver: SQLiteDriver())
        // Network engines are wrapped so an optional SSH tunnel is established
        // transparently before connecting. SQLite is a local file and ignores SSH.
        let sshEngine = LibSSH2TunnelEngine()
        await manager.register(driver: TunnelingDriver(wrapped: MySQLDriver(), engine: sshEngine))
        await manager.register(driver: TunnelingDriver(wrapped: PostgreSQLDriver(), engine: sshEngine))
        await manager.register(driver: TunnelingDriver(wrapped: RedisDriver(), engine: sshEngine))
    }
}
