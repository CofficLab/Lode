import Foundation

/// 一条已建立的 SSH 本地端口转发隧道。
///
/// 隧道在本地 `127.0.0.1` 监听 ``localPort``，把每条接入的本地连接经
/// SSH `direct-tcpip` 通道桥接到真实数据库 host:port。底层驱动只需连接
/// 本地端口，对隧道完全无感。
public protocol SSHTunnel: Sendable {
    /// 本地监听端口（连接配置会被改写为 127.0.0.1:localPort）。
    var localPort: Int { get }
    /// 隧道是否仍然健康（SSH 会话存活且监听可用）。
    func isAlive() async -> Bool
    /// 关闭隧道：停止监听并断开 SSH 会话。
    func close() async
}

/// SSH 隧道引擎抽象。生产实现基于 libssh2；测试可用 mock 替换。
public protocol SSHTunnelEngine: Sendable {
    /// 登录跳板机并建立到 `targetHost:targetPort` 的本地转发隧道。
    /// 主机密钥校验失败、认证失败等应抛出 ``DatabaseError/connectionFailed``。
    func openTunnel(ssh: ConnectionSSHConfig, targetHost: String, targetPort: Int) async throws -> any SSHTunnel
}

/// 隧道装饰器驱动：包裹真实驱动，在连接前透明地建立 SSH 隧道。
///
/// 所有连接创建都经过 `driver.connect(config:)`（core.connect / probe /
/// 池 acquire / 池重连），因此在此处装饰即可覆盖全部路径。SQLite 是本地
/// 文件，无 host，忽略 SSH 选项直接透传。
///
/// 每条连接持有自己的隧道；连接关闭时隧道随之关闭。池的 `isAlive()` 失败
/// 重连机制天然带来「隧道掉线 → 重建」的恢复能力。
public struct TunnelingDriver: DatabaseDriver {
    private let wrapped: any DatabaseDriver
    private let engine: any SSHTunnelEngine

    public init(wrapped: any DatabaseDriver, engine: any SSHTunnelEngine) {
        self.wrapped = wrapped
        self.engine = engine
    }

    public var type: DatabaseType { wrapped.type }
    public var capabilities: DatabaseCapabilities { wrapped.capabilities }

    public func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        guard type != .sqlite, let ssh = config.sshConfig else {
            return try await wrapped.connect(config: config)
        }
        let validated = try ssh.validated()
        guard let targetHost = config.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !targetHost.isEmpty else {
            throw DatabaseError.invalidConfiguration("SSH tunnel requires a database host")
        }
        let targetPort = try config.validatedNetworkPort(default: type.defaultPort, serviceName: type.rawValue)

        let tunnel = try await engine.openTunnel(ssh: validated, targetHost: targetHost, targetPort: targetPort)
        var localConfig = config
        localConfig.host = "127.0.0.1"
        localConfig.port = tunnel.localPort
        do {
            let connection = try await wrapped.connect(config: localConfig)
            return TunneledConnection(wrapped: connection, tunnel: tunnel)
        } catch {
            await tunnel.close()
            throw error
        }
    }
}

/// 把隧道生命周期绑定到数据库连接的包装器。
///
/// 所有操作透传给内层连接；`isAlive()` 同时要求内层连接与隧道均健康，
/// `close()` 先关内层连接再关隧道。存储属性均不可变 Sendable，转发皆 async，
/// 无共享可变状态，故 `@unchecked Sendable` 安全。
final class TunneledConnection: DatabaseConnection, @unchecked Sendable {
    private let wrapped: any DatabaseConnection
    private let tunnel: any SSHTunnel

    init(wrapped: any DatabaseConnection, tunnel: any SSHTunnel) {
        self.wrapped = wrapped
        self.tunnel = tunnel
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        try await wrapped.execute(sql, params: params)
    }

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        try await wrapped.query(sql, params: params)
    }

    func beginTransaction() async throws -> any DatabaseTransaction {
        try await wrapped.beginTransaction()
    }

    func close() async {
        await wrapped.close()
        await tunnel.close()
    }

    func isAlive() async -> Bool {
        guard await tunnel.isAlive() else { return false }
        return await wrapped.isAlive()
    }

    func cancel() async { await wrapped.cancel() }
}