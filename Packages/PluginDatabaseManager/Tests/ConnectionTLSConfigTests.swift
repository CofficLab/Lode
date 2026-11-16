import Foundation
import Testing
import NIOSSL
@testable import DatabaseManagerPlugin

/// TLS 证书材料模型：JSON 往返、校验、与 SSL 模式共存，以及 NIOSSL 配置映射。
struct ConnectionTLSConfigTests {
    private func baseConfig() -> DatabaseConfig {
        DatabaseConfig(name: "db", type: .postgresql, host: "db.internal", port: 5432, database: "testdb", username: "u")
    }

    @Test("TLS 配置 JSON 往返保持一致")
    func roundTrip() {
        let tls = ConnectionTLSConfig(
            caCertPath: "/certs/ca.pem",
            clientCertPath: "/certs/client.pem",
            clientKeyPath: "/certs/client.key"
        )
        let config = baseConfig().withTLSConfig(tls)
        #expect(config.tlsConfig == tls)
    }

    @Test("未设置时 tlsConfig 为 nil")
    func absentIsNil() {
        #expect(baseConfig().tlsConfig == nil)
    }

    @Test("空配置移除 tls 键；options 清空时归 nil")
    func emptyClearsKey() {
        let config = baseConfig().withTLSConfig(ConnectionTLSConfig(caCertPath: "/ca.pem"))
        #expect(config.tlsConfig != nil)
        let removed = config.withTLSConfig(nil)
        #expect(removed.tlsConfig == nil)
        #expect(removed.options == nil)
        let emptied = config.withTLSConfig(ConnectionTLSConfig())
        #expect(emptied.tlsConfig == nil)
    }

    @Test("TLS 与 SSL 模式、SSH 配置共存")
    func coexistsWithOtherOptions() {
        let config = baseConfig()
            .withSSLOption(.verifyFull)
            .withTLSConfig(ConnectionTLSConfig(caCertPath: "/ca.pem"))
            .withSSHConfig(ConnectionSSHConfig(host: "jump", username: "u", password: "p"))
        #expect(config.sslOption == .verifyFull)
        #expect(config.tlsConfig?.caCertPath == "/ca.pem")
        #expect(config.sshConfig?.host == "jump")
    }

    @Test("validated 归一化路径空白")
    func validatedTrims() throws {
        let tls = ConnectionTLSConfig(caCertPath: "  /ca.pem  ", clientCertPath: " /c.pem ", clientKeyPath: " /c.key ")
        let validated = try tls.validated()
        #expect(validated.caCertPath == "/ca.pem")
        #expect(validated.clientCertPath == "/c.pem")
        #expect(validated.clientKeyPath == "/c.key")
    }

    @Test("客户端证书缺私钥报错")
    func certRequiresKey() {
        let tls = ConnectionTLSConfig(clientCertPath: "/c.pem")
        #expect(throws: ConnectionTLSConfigError.clientCertRequiresKey) { try tls.validated() }
    }

    @Test("客户端私钥缺证书报错")
    func keyRequiresCert() {
        let tls = ConnectionTLSConfig(clientKeyPath: "/c.key")
        #expect(throws: ConnectionTLSConfigError.clientKeyRequiresCert) { try tls.validated() }
    }

    @Test("仅 CA 合法（无需客户端证书）")
    func caOnlyValid() throws {
        let validated = try ConnectionTLSConfig(caCertPath: "/ca.pem").validated()
        #expect(validated.caCertPath == "/ca.pem")
        #expect(validated.clientCertPath == nil)
    }

    @Test("证书校验强度映射到 NIOSSL", arguments: [
        (ConnectionSSLOption.disable, CertificateVerification.none),
        (.prefer, .none),
        (.require, .none),
        (.verifyCA, .noHostnameVerification),
        (.verifyFull, .fullVerification)
    ])
    func verificationMapping(mode: ConnectionSSLOption, expected: CertificateVerification) {
        #expect(mode.makeTLSConfiguration().certificateVerification == expected)
    }

    @Test("CA 文件成为信任根")
    func caBecomesTrustRoot() {
        let config = ConnectionSSLOption.verifyFull.makeTLSConfiguration(tls: ConnectionTLSConfig(caCertPath: "/ca.pem"))
        #expect(config.trustRoots == .file("/ca.pem"))
    }

    @Test("客户端证书与私钥进入配置")
    func clientCertAndKey() {
        let tls = ConnectionTLSConfig(clientCertPath: "/c.pem", clientKeyPath: "/c.key")
        let config = ConnectionSSLOption.require.makeTLSConfiguration(tls: tls)
        #expect(config.certificateChain == [.file("/c.pem")])
        #expect(config.privateKey == .file("/c.key"))
    }

    @Test("无证书材料时沿用默认信任根")
    func noMaterialKeepsDefault() {
        let config = ConnectionSSLOption.verifyFull.makeTLSConfiguration(tls: nil)
        #expect(config.trustRoots == .default)
        #expect(config.certificateChain.isEmpty)
        #expect(config.privateKey == nil)
    }

    @Test("enablesTLS：disable 不加密，其余加密")
    func enablesTLS() {
        #expect(ConnectionSSLOption.disable.enablesTLS == false)
        #expect(ConnectionSSLOption.prefer.enablesTLS == true)
        #expect(ConnectionSSLOption.require.enablesTLS == true)
        #expect(ConnectionSSLOption.verifyCA.enablesTLS == true)
        #expect(ConnectionSSLOption.verifyFull.enablesTLS == true)
    }
}