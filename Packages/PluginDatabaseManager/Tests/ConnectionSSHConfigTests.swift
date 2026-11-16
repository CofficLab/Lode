import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// SSH 隧道配置模型：JSON 往返、校验、与 SSL 选项共存。
struct ConnectionSSHConfigTests {
    private func baseConfig() -> DatabaseConfig {
        DatabaseConfig(name: "db", type: .mysql, host: "db.internal", port: 3306, database: "testdb", username: "u")
    }

    @Test("SSH 配置 JSON 往返保持一致")
    func roundTrip() {
        let ssh = ConnectionSSHConfig(
            host: "jump.example.com", port: 2222, username: "jumpuser",
            authMethod: .privateKey, privateKeyPath: "/keys/id_ed25519",
            passphrase: "secret", knownHostsPath: "/known_hosts"
        )
        let config = baseConfig().withSSHConfig(ssh)
        #expect(config.sshConfig == ssh)
    }

    @Test("未设置时 sshConfig 为 nil")
    func absentIsNil() {
        #expect(baseConfig().sshConfig == nil)
    }

    @Test("传 nil 移除 ssh 键；options 清空时归 nil")
    func removeClearsKey() {
        let config = baseConfig().withSSHConfig(ConnectionSSHConfig(host: "h", username: "u", password: "p"))
        #expect(config.sshConfig != nil)
        let removed = config.withSSHConfig(nil)
        #expect(removed.sshConfig == nil)
        #expect(removed.options == nil)
    }

    @Test("损坏的 JSON 视为未配置")
    func corruptJSONIsNil() {
        var config = baseConfig()
        config.options = ["ssh": "{not valid json"]
        #expect(config.sshConfig == nil)
    }

    @Test("SSH 与 SSL 选项共存互不覆盖")
    func coexistsWithSSL() {
        let ssh = ConnectionSSHConfig(host: "h", username: "u", authMethod: .agent)
        let config = baseConfig()
            .withSSLOption(.verifyFull)
            .withSSHConfig(ssh)
        #expect(config.sshConfig == ssh)
        #expect(config.sslOption == .verifyFull)
        // 移除 SSH 不应影响 SSL
        let noSSH = config.withSSHConfig(nil)
        #expect(noSSH.sslOption == .verifyFull)
        #expect(noSSH.sshConfig == nil)
    }

    @Test("默认端口为 22")
    func defaultPort() {
        #expect(ConnectionSSHConfig(host: "h", username: "u").port == 22)
    }

    // MARK: - 校验

    @Test("合法密码配置通过校验并 trim host/username")
    func validPassword() throws {
        let ssh = ConnectionSSHConfig(host: "  jump  ", username: "  user  ", password: "pw")
        let normalized = try ssh.validated()
        #expect(normalized.host == "jump")
        #expect(normalized.username == "user")
    }

    @Test("缺 host 抛 missingHost")
    func missingHost() {
        let ssh = ConnectionSSHConfig(host: "   ", username: "u", password: "p")
        #expect(throws: ConnectionSSHConfigError.missingHost) { try ssh.validated() }
    }

    @Test("非法端口抛 invalidPort", arguments: [0, -1, 65536, 99999])
    func invalidPort(port: Int) {
        let ssh = ConnectionSSHConfig(host: "h", port: port, username: "u", password: "p")
        #expect(throws: ConnectionSSHConfigError.invalidPort) { try ssh.validated() }
    }

    @Test("缺 username 抛 missingUsername")
    func missingUsername() {
        let ssh = ConnectionSSHConfig(host: "h", username: "  ", password: "p")
        #expect(throws: ConnectionSSHConfigError.missingUsername) { try ssh.validated() }
    }

    @Test("密码认证缺密码抛 missingPassword")
    func passwordAuthNeedsPassword() {
        let ssh = ConnectionSSHConfig(host: "h", username: "u", authMethod: .password, password: nil)
        #expect(throws: ConnectionSSHConfigError.missingPassword) { try ssh.validated() }
    }

    @Test("私钥认证缺路径抛 missingPrivateKeyPath")
    func keyAuthNeedsPath() {
        let ssh = ConnectionSSHConfig(host: "h", username: "u", authMethod: .privateKey, privateKeyPath: "  ")
        #expect(throws: ConnectionSSHConfigError.missingPrivateKeyPath) { try ssh.validated() }
    }

    @Test("私钥认证 trim 路径")
    func keyAuthTrimsPath() throws {
        let ssh = ConnectionSSHConfig(host: "h", username: "u", authMethod: .privateKey, privateKeyPath: "  /keys/id  ")
        #expect(try ssh.validated().privateKeyPath == "/keys/id")
    }

    @Test("agent 认证无需密码或私钥")
    func agentAuthNeedsNothingExtra() throws {
        let ssh = ConnectionSSHConfig(host: "h", username: "u", authMethod: .agent)
        #expect(try ssh.validated().authMethod == .agent)
    }
}