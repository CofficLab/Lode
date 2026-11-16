import Foundation
import Network
import Security

/// Redis 走 Network.framework 的 `NWConnection`，TLS 通过 `NWProtocolTLS.Options`
/// 表达（与 MySQL/PG 的 NIOSSL 路径不同）。这里把 ``ConnectionSSLOption`` 的校验
/// 强度翻译为 Security 框架的信任评估：
/// - require / prefer：加密但不校验证书（自签/dev 服务器）。
/// - verifyCA：用自定义 CA（或系统信任根）校验证书链，不校验主机名。
/// - verifyFull：额外校验主机名（SAN/CN）。
///
/// 客户端证书（mTLS）由 MySQL/PG 的 NIOSSL 路径支持；Redis 仅做服务端认证。
enum RedisTLSSupport {
    /// 构造启用 TLS 的连接参数。调用方已确认 `mode.enablesTLS == true`。
    static func makeParameters(mode: ConnectionSSLOption, tls: ConnectionTLSConfig?, host: String) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)

        let caDERs = derCertificates(pemPath: tls?.normalizedCA)
        let verifyHostname = mode == .verifyFull
        let queue = DispatchQueue(label: "databasekit.redis.tls.verify")

        if mode == .require || mode == .prefer {
            sec_protocol_options_set_verify_block(secOptions, { _, _, complete in
                complete(true)
            }, queue)
        } else {
            sec_protocol_options_set_verify_block(secOptions, { _, trust, complete in
                complete(evaluate(trust: trust, caDERs: caDERs, hostname: verifyHostname ? host : nil))
            }, queue)
        }

        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    /// 用 Security 框架评估服务端信任。提供 CA 时仅以这些 CA 为锚（自签 CA 无需系统信任）。
    static func evaluate(trust: sec_trust_t, caDERs: [Data], hostname: String?) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        if !caDERs.isEmpty {
            let anchors = caDERs.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            SecTrustSetAnchorCertificates(secTrust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(secTrust, true)
        }
        if let hostname {
            SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, hostname as CFString))
        } else {
            SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
        }
        var error: CFError?
        return SecTrustEvaluateWithError(secTrust, &error)
    }

    /// 从 PEM 文件提取所有证书的 DER 数据（支持证书链）。读取失败返回空数组。
    static func derCertificates(pemPath: String?) -> [Data] {
        guard let path = pemPath,
              let pem = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: "-----BEGIN CERTIFICATE-----([\\s\\S]*?)-----END CERTIFICATE-----"
        ) else { return [] }
        let range = NSRange(pem.startIndex..<pem.endIndex, in: pem)
        var result: [Data] = []
        regex.enumerateMatches(in: pem, range: range) { match, _, _ in
            guard let match, let bodyRange = Range(match.range(at: 1), in: pem) else { return }
            let base64 = String(pem[bodyRange])
            if let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                result.append(der)
            }
        }
        return result
    }
}