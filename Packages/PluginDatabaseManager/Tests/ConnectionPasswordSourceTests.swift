import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// 密码来源模型：options JSON 往返、默认 Keychain 不写键、按来源校验必填字段、与其它选项共存。
struct ConnectionPasswordSourceTests {
    private func baseConfig() -> DatabaseConfig {
        DatabaseConfig(name: "db", type: .postgresql, host: "db.internal", port: 5432, database: "testdb", username: "u")
    }

    @Test("未设置时 passwordSource 为 nil（视为默认 Keychain）")
    func absentIsNil() {
        #expect(baseConfig().passwordSource == nil)
    }

    @Test("各来源 JSON 往返保持一致", arguments: PasswordSourceKind.allCases)
    func roundTrip(kind: PasswordSourceKind) {
        let source = ConnectionPasswordSource(
            kind: kind,
            filePath: "/run/secrets/db",
            variableName: "DB_PASSWORD",
            command: "op read op://vault/db/password"
        )
        let config = baseConfig().withPasswordSource(source)
        if source.isDefault {
            #expect(config.passwordSource == nil)
            #expect(config.options == nil)
        } else {
            #expect(config.passwordSource == source)
        }
    }

    @Test("默认 Keychain 来源移除键并归 nil options")
    func keychainRemovesKey() {
        let config = baseConfig().withPasswordSource(ConnectionPasswordSource(kind: .command, command: "x"))
        #expect(config.passwordSource != nil)
        let cleared = config.withPasswordSource(ConnectionPasswordSource(kind: .keychain))
        #expect(cleared.passwordSource == nil)
        #expect(cleared.options == nil)
        let nilCleared = config.withPasswordSource(nil)
        #expect(nilCleared.passwordSource == nil)
        #expect(nilCleared.options == nil)
    }

    @Test("损坏的 JSON 回退 nil 而非崩溃")
    func corruptJSONFallsBack() {
        var config = baseConfig()
        config.options = ["passwordSource": "{not json"]
        #expect(config.passwordSource == nil)
    }

    @Test("isDefault 仅对 Keychain 为真", arguments: PasswordSourceKind.allCases)
    func isDefaultOnlyKeychain(kind: PasswordSourceKind) {
        #expect(ConnectionPasswordSource(kind: kind).isDefault == (kind == .keychain))
    }

    @Test("file 来源缺路径校验失败")
    func fileRequiresPath() {
        #expect(throws: ConnectionPasswordSourceError.missingFilePath) {
            _ = try ConnectionPasswordSource(kind: .file).validated()
        }
        #expect(throws: ConnectionPasswordSourceError.missingFilePath) {
            _ = try ConnectionPasswordSource(kind: .file, filePath: "   ").validated()
        }
    }

    @Test("environment 来源缺变量名校验失败")
    func environmentRequiresName() {
        #expect(throws: ConnectionPasswordSourceError.missingVariableName) {
            _ = try ConnectionPasswordSource(kind: .environment).validated()
        }
    }

    @Test("command 来源缺命令校验失败")
    func commandRequiresCommand() {
        #expect(throws: ConnectionPasswordSourceError.missingCommand) {
            _ = try ConnectionPasswordSource(kind: .command).validated()
        }
    }

    @Test("validated trim 外层空白并保留有效字段")
    func validatedTrims() throws {
        let source = ConnectionPasswordSource(kind: .file, filePath: "  /run/secrets/db  ")
        let validated = try source.validated()
        #expect(validated.filePath == "/run/secrets/db")
        let env = try ConnectionPasswordSource(kind: .environment, variableName: " DB_PASSWORD ").validated()
        #expect(env.variableName == "DB_PASSWORD")
        let cmd = try ConnectionPasswordSource(kind: .command, command: "  echo hi  ").validated()
        #expect(cmd.command == "echo hi")
    }

    @Test("keychain/askEveryTime 无必填字段也通过校验")
    func interactiveKindsValidate() throws {
        _ = try ConnectionPasswordSource(kind: .keychain).validated()
        _ = try ConnectionPasswordSource(kind: .askEveryTime).validated()
    }

    @Test("密码来源与安全模式、分组、SSL、SSH 共存")
    func coexistsWithOtherOptions() {
        let config = baseConfig()
            .withPasswordSource(ConnectionPasswordSource(kind: .environment, variableName: "DB_PASSWORD"))
            .withGroup("Production")
            .withConnectionColor(.red)
            .withSafeMode(.readOnly)
            .withSSLOption(.verifyFull)
            .withSSHConfig(ConnectionSSHConfig(host: "jump", username: "u", password: "p"))
        #expect(config.passwordSource?.kind == .environment)
        #expect(config.passwordSource?.variableName == "DB_PASSWORD")
        #expect(config.group == "Production")
        #expect(config.connectionColor == .red)
        #expect(config.safeMode == .readOnly)
        #expect(config.sslOption == .verifyFull)
        #expect(config.sshConfig?.host == "jump")
    }

    @Test("displayTitle 覆盖全部 case 且非空", arguments: PasswordSourceKind.allCases)
    func titlesNonEmpty(kind: PasswordSourceKind) {
        #expect(!kind.displayTitle.isEmpty)
    }
}

/// 密码来源解析器：注入环境表/文件读取/命令执行，离线验证各来源解析与失败路径。
/// 安全断言：command 失败只携带退出码，不含命令输出。
struct PasswordSourceResolverTests {
    @Test("keychain 来源直接返回注入的 Keychain 密码")
    func keychainReturnsStored() async throws {
        let resolver = PasswordSourceResolver(environment: [:])
        let value = try await resolver.resolve(ConnectionPasswordSource(kind: .keychain), keychainPassword: "s3cret")
        #expect(value == "s3cret")
        let nilValue = try await resolver.resolve(ConnectionPasswordSource(kind: .keychain), keychainPassword: nil)
        #expect(nilValue == nil)
    }

    @Test("askEveryTime 返回 nil（交由 VM 弹窗）")
    func askEveryTimeReturnsNil() async throws {
        let resolver = PasswordSourceResolver(environment: [:])
        let value = try await resolver.resolve(ConnectionPasswordSource(kind: .askEveryTime), keychainPassword: "ignored")
        #expect(value == nil)
    }

    @Test("file 来源读取内容并去掉尾部换行")
    func fileReadsAndTrims() async throws {
        let resolver = PasswordSourceResolver(
            environment: [:],
            readFile: { path in
                #expect(path == "/run/secrets/db")
                return "filepass\n"
            }
        )
        let value = try await resolver.resolve(ConnectionPasswordSource(kind: .file, filePath: "/run/secrets/db"), keychainPassword: nil)
        #expect(value == "filepass")
    }

    @Test("file 读取抛错归类为 fileUnreadable")
    func fileUnreadable() async {
        struct Boom: Error {}
        let resolver = PasswordSourceResolver(environment: [:], readFile: { _ in throw Boom() })
        await #expect(throws: PasswordSourceResolutionError.fileUnreadable(path: "/missing")) {
            _ = try await resolver.resolve(ConnectionPasswordSource(kind: .file, filePath: "/missing"), keychainPassword: nil)
        }
    }

    @Test("file 来源缺路径抛 missingFilePath")
    func fileMissingPath() async {
        let resolver = PasswordSourceResolver(environment: [:])
        await #expect(throws: ConnectionPasswordSourceError.missingFilePath) {
            _ = try await resolver.resolve(ConnectionPasswordSource(kind: .file), keychainPassword: nil)
        }
    }

    @Test("environment 来源从注入环境表取值")
    func environmentReads() async throws {
        let resolver = PasswordSourceResolver(environment: ["DB_PASSWORD": "envpass"])
        let value = try await resolver.resolve(ConnectionPasswordSource(kind: .environment, variableName: "DB_PASSWORD"), keychainPassword: nil)
        #expect(value == "envpass")
    }

    @Test("environment 变量未设置抛 variableNotSet")
    func environmentNotSet() async {
        let resolver = PasswordSourceResolver(environment: [:])
        await #expect(throws: PasswordSourceResolutionError.variableNotSet(name: "DB_PASSWORD")) {
            _ = try await resolver.resolve(ConnectionPasswordSource(kind: .environment, variableName: "DB_PASSWORD"), keychainPassword: nil)
        }
    }

    @Test("environment 来源缺变量名抛 missingVariableName")
    func environmentMissingName() async {
        let resolver = PasswordSourceResolver(environment: [:])
        await #expect(throws: ConnectionPasswordSourceError.missingVariableName) {
            _ = try await resolver.resolve(ConnectionPasswordSource(kind: .environment), keychainPassword: nil)
        }
    }

    @Test("command 来源执行注入命令并去掉尾部换行")
    func commandRunsAndTrims() async throws {
        let resolver = PasswordSourceResolver(
            environment: [:],
            runCommand: { command in
                #expect(command == "op read op://vault/db/password")
                return "cmdpass\n"
            }
        )
        let value = try await resolver.resolve(ConnectionPasswordSource(kind: .command, command: "op read op://vault/db/password"), keychainPassword: nil)
        #expect(value == "cmdpass")
    }

    @Test("command 执行抛错原样传播（只含退出码，不含输出）")
    func commandFailurePropagates() async {
        let resolver = PasswordSourceResolver(
            environment: [:],
            runCommand: { _ in throw PasswordSourceResolutionError.commandFailed(status: 3) }
        )
        await #expect(throws: PasswordSourceResolutionError.commandFailed(status: 3)) {
            _ = try await resolver.resolve(ConnectionPasswordSource(kind: .command, command: "false"), keychainPassword: nil)
        }
    }

    @Test("command 来源缺命令抛 missingCommand")
    func commandMissing() async {
        let resolver = PasswordSourceResolver(environment: [:])
        await #expect(throws: ConnectionPasswordSourceError.missingCommand) {
            _ = try await resolver.resolve(ConnectionPasswordSource(kind: .command), keychainPassword: nil)
        }
    }

    @Test("trimTrailingNewlines 去掉尾部 \\n/\\r 但保留内部与尾部空格")
    func trimTrailingNewlines() {
        #expect(PasswordSourceResolver.trimTrailingNewlines("pass\n") == "pass")
        #expect(PasswordSourceResolver.trimTrailingNewlines("pass\r\n") == "pass")
        #expect(PasswordSourceResolver.trimTrailingNewlines("pass\n\n\n") == "pass")
        #expect(PasswordSourceResolver.trimTrailingNewlines("pass ") == "pass ")
        #expect(PasswordSourceResolver.trimTrailingNewlines("pa\nss") == "pa\nss")
        #expect(PasswordSourceResolver.trimTrailingNewlines("  pass  ") == "  pass  ")
        #expect(PasswordSourceResolver.trimTrailingNewlines("") == "")
        #expect(PasswordSourceResolver.trimTrailingNewlines("\n") == "")
    }

    @Test("默认执行器真实运行 /bin/sh 命令并去掉尾部换行")
    func shellCommandRunsRealProcess() async throws {
        let resolver = PasswordSourceResolver(environment: [:])
        let value = try await resolver.resolve(ConnectionPasswordSource(kind: .command, command: "echo shellpass"), keychainPassword: nil)
        #expect(value == "shellpass")
    }

    @Test("默认执行器对非零退出只报退出码")
    func shellCommandReportsExitStatus() async {
        let resolver = PasswordSourceResolver(environment: [:])
        await #expect(throws: PasswordSourceResolutionError.commandFailed(status: 7)) {
            _ = try await resolver.resolve(ConnectionPasswordSource(kind: .command, command: "exit 7"), keychainPassword: nil)
        }
    }
}