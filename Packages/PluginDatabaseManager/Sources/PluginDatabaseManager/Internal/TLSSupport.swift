import Foundation
import NIOSSL

/// 把 ``ConnectionSSLOption`` 翻译为 NIOSSL 的 `TLSConfiguration`。
///
/// 各模式的证书校验强度：
/// - disable / prefer / require：`certificateVerification = .none`（适合自签证书/dev 服务器）
/// - verifyCA：`certificateVerification = .noHostnameVerification`（校验 CA，不校验主机名）
/// - verifyFull：`certificateVerification = .fullVerification`（最严格）
extension ConnectionSSLOption {
    /// 构造客户端 TLS 配置。
    ///
    /// - Parameter tls: 可选的自定义证书材料。CA 文件作为信任根（自签服务器
    ///   通过 verify-ca / verify-full 所需）；客户端证书与私钥用于双向 TLS。
    ///   未提供 CA 时沿用系统默认信任根。
    public func makeTLSConfiguration(tls: ConnectionTLSConfig? = nil) -> TLSConfiguration {
        var config = TLSConfiguration.makeClientConfiguration()
        switch self {
        case .disable, .prefer, .require:
            config.certificateVerification = .none
        case .verifyCA:
            config.certificateVerification = .noHostnameVerification
        case .verifyFull:
            config.certificateVerification = .fullVerification
        }
        if let ca = tls?.normalizedCA {
            config.trustRoots = .file(ca)
        }
        if let cert = tls?.normalizedClientCert {
            config.certificateChain = [.file(cert)]
        }
        if let key = tls?.normalizedClientKey {
            config.privateKey = .file(key)
        }
        return config
    }

    /// 是否需要真正建立 TLS 通道。disable 与 nil 视为不加密。
    public var enablesTLS: Bool {
        switch self {
        case .disable: return false
        case .prefer, .require, .verifyCA, .verifyFull: return true
        }
    }
}
