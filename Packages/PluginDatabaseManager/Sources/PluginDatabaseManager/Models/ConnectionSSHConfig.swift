import Foundation

/// SSH 跳板隧道的认证方式。
public enum SSHAuthMethod: String, Codable, CaseIterable, Sendable {
    /// 密码认证。
    case password
    /// 私钥文件认证（可带 passphrase）。
    case privateKey
    /// 通过 ssh-agent 认证（使用 `SSH_AUTH_SOCK`）。
    case agent

    public var displayTitle: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private Key"
        case .agent: return "SSH Agent"
        }
    }
}

/// SSH 跳板隧道配置。整体以 JSON 存进 ``DatabaseConfig/options`` 的 `"ssh"` 键，
/// 存在即表示启用隧道。仅对网络引擎（MySQL/PostgreSQL/Redis）有意义，
/// SQLite 是本地文件，驱动层会忽略该选项。
///
/// 隧道工作方式：先 SSH 登录跳板机，再在本地 `127.0.0.1` 起一个临时监听端口，
/// 把每条本地连接经 libssh2 `direct-tcpip` 通道桥接到真实数据库 host:port，
/// 随后把连接配置改写为本地端口交给底层驱动。对上层完全透明。
public struct ConnectionSSHConfig: Codable, Hashable, Sendable {
    /// 跳板机主机名或地址。
    public var host: String
    /// 跳板机 SSH 端口，默认 22。
    public var port: Int
    /// 跳板机登录用户名。
    public var username: String
    /// 认证方式。
    public var authMethod: SSHAuthMethod
    /// 密码（`authMethod == .password` 时使用）。
    public var password: String?
    /// 私钥文件路径（`authMethod == .privateKey` 时使用）。
    public var privateKeyPath: String?
    /// 私钥 passphrase（加密私钥时使用，明文私钥留空）。
    public var passphrase: String?
    /// known-hosts 文件路径，用于主机密钥校验。nil 时由驱动用默认存储。
    public var knownHostsPath: String?

    public init(
        host: String,
        port: Int = 22,
        username: String,
        authMethod: SSHAuthMethod = .password,
        password: String? = nil,
        privateKeyPath: String? = nil,
        passphrase: String? = nil,
        knownHostsPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.passphrase = passphrase
        self.knownHostsPath = knownHostsPath
    }
}

public enum ConnectionSSHConfigError: LocalizedError, Equatable {
    case missingHost
    case invalidPort
    case missingUsername
    case missingPassword
    case missingPrivateKeyPath

    public var errorDescription: String? {
        switch self {
        case .missingHost: return "SSH host is required."
        case .invalidPort: return "SSH port must be a number from 1 to 65535."
        case .missingUsername: return "SSH username is required."
        case .missingPassword: return "SSH password is required for password authentication."
        case .missingPrivateKeyPath: return "A private key file is required for key authentication."
        }
    }
}

public extension ConnectionSSHConfig {
    /// 校验并归一化（trim host/username，校验端口与认证方式所需字段）。
    /// 返回归一化后的副本；校验失败抛出 ``ConnectionSSHConfigError``。
    func validated() throws -> ConnectionSSHConfig {
        var copy = self
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.host.isEmpty else { throw ConnectionSSHConfigError.missingHost }
        guard (1...65535).contains(port) else { throw ConnectionSSHConfigError.invalidPort }
        guard !copy.username.isEmpty else { throw ConnectionSSHConfigError.missingUsername }
        switch authMethod {
        case .password:
            guard let password, !password.isEmpty else {
                throw ConnectionSSHConfigError.missingPassword
            }
        case .privateKey:
            let path = (privateKeyPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { throw ConnectionSSHConfigError.missingPrivateKeyPath }
            copy.privateKeyPath = path
        case .agent:
            break
        }
        return copy
    }
}

public extension DatabaseConfig {
    private static let sshConfigKey = "ssh"

    /// 当前配置的 SSH 隧道设置。未设置或 JSON 损坏时返回 nil（视为不启用隧道）。
    var sshConfig: ConnectionSSHConfig? {
        guard let raw = options?[Self.sshConfigKey], let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ConnectionSSHConfig.self, from: data)
    }

    /// 返回一份应用了新 SSH 配置的副本（nil 表示移除该选项，关闭隧道）。
    func withSSHConfig(_ config: ConnectionSSHConfig?) -> DatabaseConfig {
        var copy = self
        var opts = copy.options ?? [:]
        if let config, let data = try? JSONEncoder().encode(config),
           let json = String(data: data, encoding: .utf8) {
            opts[Self.sshConfigKey] = json
        } else {
            opts.removeValue(forKey: Self.sshConfigKey)
        }
        copy.options = opts.isEmpty ? nil : opts
        return copy
    }
}