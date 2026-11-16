import Foundation

/// 连接的 TLS 证书材料。整体以 JSON 存进 ``DatabaseConfig/options`` 的 `"tls"` 键，
/// 与 ``ConnectionSSLOption``（加密模式）配合使用：模式决定是否加密与校验强度，
/// 本配置提供自定义信任根与客户端证书。仅对支持 TLS 的网络引擎有意义。
///
/// 典型用途：自签证书的服务器需要指定 CA 文件才能通过 verify-ca / verify-full；
/// 双向 TLS（mTLS）需要客户端证书与对应私钥。
public struct ConnectionTLSConfig: Codable, Hashable, Sendable {
    /// 自定义 CA 证书文件路径（PEM）。verify-ca / verify-full 时作为信任根。
    public var caCertPath: String?
    /// 客户端证书文件路径（PEM），用于双向 TLS。
    public var clientCertPath: String?
    /// 客户端私钥文件路径（PEM），与客户端证书配对。
    public var clientKeyPath: String?

    public init(
        caCertPath: String? = nil,
        clientCertPath: String? = nil,
        clientKeyPath: String? = nil
    ) {
        self.caCertPath = caCertPath
        self.clientCertPath = clientCertPath
        self.clientKeyPath = clientKeyPath
    }

    /// 是否不含任何证书材料（全是 nil 或空白）。
    public var isEmpty: Bool {
        normalizedCA == nil && normalizedClientCert == nil && normalizedClientKey == nil
    }

    var normalizedCA: String? { Self.normalize(caCertPath) }
    var normalizedClientCert: String? { Self.normalize(clientCertPath) }
    var normalizedClientKey: String? { Self.normalize(clientKeyPath) }

    private static func normalize(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public enum ConnectionTLSConfigError: LocalizedError, Equatable {
    case clientCertRequiresKey
    case clientKeyRequiresCert

    public var errorDescription: String? {
        switch self {
        case .clientCertRequiresKey: return "A client certificate requires a matching private key file."
        case .clientKeyRequiresCert: return "A client private key requires a matching certificate file."
        }
    }
}

public extension ConnectionTLSConfig {
    /// 校验并归一化（trim 路径，客户端证书与私钥必须成对）。
    /// 返回归一化后的副本；校验失败抛出 ``ConnectionTLSConfigError``。
    func validated() throws -> ConnectionTLSConfig {
        let cert = normalizedClientCert
        let key = normalizedClientKey
        if cert != nil && key == nil { throw ConnectionTLSConfigError.clientCertRequiresKey }
        if key != nil && cert == nil { throw ConnectionTLSConfigError.clientKeyRequiresCert }
        return ConnectionTLSConfig(
            caCertPath: normalizedCA,
            clientCertPath: cert,
            clientKeyPath: key
        )
    }
}

public extension DatabaseConfig {
    private static let tlsConfigKey = "tls"

    /// 当前配置的 TLS 证书材料。未设置或 JSON 损坏时返回 nil。
    var tlsConfig: ConnectionTLSConfig? {
        guard let raw = options?[Self.tlsConfigKey], let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ConnectionTLSConfig.self, from: data)
    }

    /// 返回一份应用了新 TLS 证书材料的副本（nil 或空配置表示移除该键）。
    func withTLSConfig(_ config: ConnectionTLSConfig?) -> DatabaseConfig {
        var copy = self
        var opts = copy.options ?? [:]
        if let config, !config.isEmpty, let data = try? JSONEncoder().encode(config),
           let json = String(data: data, encoding: .utf8) {
            opts[Self.tlsConfigKey] = json
        } else {
            opts.removeValue(forKey: Self.tlsConfigKey)
        }
        copy.options = opts.isEmpty ? nil : opts
        return copy
    }
}