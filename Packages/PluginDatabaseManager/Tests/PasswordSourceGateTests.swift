@testable import DatabaseManagerPlugin
import Foundation
import Testing

/// 密码来源闸门（P4-7b）：用记录型假驱动验证「解析出的密码进连接副本、原始配置不被污染」，
/// 以及 command 确认闸门 / askEveryTime 询问闸门的批准、取消、失败与代际取消路径。
/// 全部离线：环境/文件/命令依赖均注入，不触达真实数据库或本机命令。

private actor PasswordFakeConnection: DatabaseConnection {
    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        QueryResult(columns: ["n"], rows: [[.integer(1)]], rowsAffected: 0)
    }
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 1 }
    func beginTransaction() async throws -> any DatabaseTransaction { PasswordFakeTransaction() }
    func close() async {}
    func isAlive() async -> Bool { true }
    func cancel() async {}
}

private struct PasswordFakeTransaction: DatabaseTransaction {
    func commit() async throws {}
    func rollback() async throws {}
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
}

/// 记录每次 connect 收到的配置，用于断言驱动拿到的是「已解析密码」的副本。
private actor PasswordFakeDriver: DatabaseDriver {
    nonisolated let type: DatabaseType
    private(set) var connectCount = 0
    private(set) var lastConnectConfig: DatabaseConfig?
    let connection: PasswordFakeConnection

    init(type: DatabaseType = .mysql, connection: PasswordFakeConnection) {
        self.type = type
        self.connection = connection
    }

    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        connectCount += 1
        lastConnectConfig = config
        return connection
    }
}

/// 命令执行间谍：记录调用次数，可配置输出/失败，验证「批准前绝不执行」。
private actor CommandSpy {
    private(set) var count = 0
    private var output = "cmdpass\n"
    private var failure: (any Error)?
    func setOutput(_ value: String) { output = value }
    func setFailure(_ error: (any Error)?) { failure = error }
    func run() async throws -> String {
        count += 1
        if let failure { throw failure }
        return output
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PasswordSourceGateTests {
    private func makeSUT() async -> (DatabaseViewModel, PasswordFakeDriver) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let driver = PasswordFakeDriver(connection: PasswordFakeConnection())
        await manager.register(driver: driver)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, driver)
    }

    private func makeConfig(password: String? = nil) -> DatabaseConfig {
        DatabaseConfig(name: "pw", type: .mysql, host: "127.0.0.1", database: "testdb", username: "u", password: password)
    }

    private func waitForPrompt(_ vm: DatabaseViewModel) async -> Bool {
        for _ in 0..<5000 {
            if vm.passwordPrompt != nil { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForCommandConfirmation(_ vm: DatabaseViewModel) async -> Bool {
        for _ in 0..<5000 {
            if vm.commandConfirmation != nil { return true }
            await Task.yield()
        }
        return false
    }

    private func isCancelled(_ error: (any Error)?) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        if case .cancelled = error { return true }
        return false
    }

    // MARK: - 静态来源解析进连接副本

    @Test func keychainDefaultPassesStoredPassword() async throws {
        let (vm, driver) = await makeSUT()
        try await vm.testConnection(config: makeConfig(password: "stored"))
        #expect(await driver.lastConnectConfig?.password == "stored")
        #expect(vm.passwordPrompt == nil)
        #expect(vm.commandConfirmation == nil)
    }

    @Test func fileSourceResolvesIntoProbeConfig() async throws {
        let (vm, driver) = await makeSUT()
        vm.passwordResolver = PasswordSourceResolver(environment: [:], readFile: { _ in "filepass\n" })
        let config = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .file, filePath: "/run/secrets/db"))
        try await vm.testConnection(config: config)
        #expect(await driver.lastConnectConfig?.password == "filepass")
    }

    @Test func environmentSourceResolves() async throws {
        let (vm, driver) = await makeSUT()
        vm.passwordResolver = PasswordSourceResolver(environment: ["DB_PASSWORD": "envpass"])
        let config = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .environment, variableName: "DB_PASSWORD"))
        try await vm.testConnection(config: config)
        #expect(await driver.lastConnectConfig?.password == "envpass")
    }

    // MARK: - askEveryTime 询问闸门

    @Test func askEveryTimePromptsThenUsesEnteredPassword() async throws {
        let (vm, driver) = await makeSUT()
        let config = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .askEveryTime))
        let task = Task { try await vm.testConnection(config: config) }
        #expect(await waitForPrompt(vm))
        #expect(vm.passwordPrompt?.connectionName == "pw")
        #expect(vm.passwordPrompt?.username == "u")
        // 询问挂起期间尚未触达驱动。
        #expect(await driver.connectCount == 0)
        vm.resolvePasswordPrompt("typedpass")
        try await task.value
        #expect(await driver.lastConnectConfig?.password == "typedpass")
        #expect(vm.passwordPrompt == nil)
    }

    @Test func askEveryTimeCancelAbortsConnect() async {
        let (vm, driver) = await makeSUT()
        let config = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .askEveryTime))
        let task = Task { try await vm.testConnection(config: config) }
        #expect(await waitForPrompt(vm))
        vm.resolvePasswordPrompt(nil)
        var thrown: (any Error)?
        do { try await task.value } catch { thrown = error }
        #expect(isCancelled(thrown))
        #expect(await driver.connectCount == 0)
        #expect(vm.passwordPrompt == nil)
    }

    // MARK: - command 确认闸门

    @Test func commandConfirmsBeforeRunning() async throws {
        let (vm, driver) = await makeSUT()
        let spy = CommandSpy()
        vm.passwordResolver = PasswordSourceResolver(environment: [:], runCommand: { _ in try await spy.run() })
        let config = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .command, command: "op read op://vault/db/password"))
        let task = Task { try await vm.testConnection(config: config) }
        #expect(await waitForCommandConfirmation(vm))
        #expect(vm.commandConfirmation?.command == "op read op://vault/db/password")
        #expect(vm.commandConfirmation?.connectionName == "pw")
        // 批准前命令绝不执行、驱动绝不触达。
        #expect(await spy.count == 0)
        #expect(await driver.connectCount == 0)
        vm.resolveCommandConfirmation(true)
        try await task.value
        #expect(await spy.count == 1)
        #expect(await driver.lastConnectConfig?.password == "cmdpass")
        #expect(vm.commandConfirmation == nil)
    }

    @Test func commandDeclinedNeverRuns() async {
        let (vm, driver) = await makeSUT()
        let spy = CommandSpy()
        vm.passwordResolver = PasswordSourceResolver(environment: [:], runCommand: { _ in try await spy.run() })
        let config = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .command, command: "op read op://vault/db/password"))
        let task = Task { try await vm.testConnection(config: config) }
        #expect(await waitForCommandConfirmation(vm))
        vm.resolveCommandConfirmation(false)
        var thrown: (any Error)?
        do { try await task.value } catch { thrown = error }
        #expect(isCancelled(thrown))
        #expect(await spy.count == 0)
        #expect(await driver.connectCount == 0)
        #expect(vm.commandConfirmation == nil)
    }

    @Test func commandFailureReportsExitCodeOnly() async {
        let (vm, driver) = await makeSUT()
        let spy = CommandSpy()
        await spy.setFailure(PasswordSourceResolutionError.commandFailed(status: 3))
        vm.passwordResolver = PasswordSourceResolver(environment: [:], runCommand: { _ in try await spy.run() })
        let config = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .command, command: "false"))
        let task = Task { try await vm.testConnection(config: config) }
        #expect(await waitForCommandConfirmation(vm))
        vm.resolveCommandConfirmation(true)
        var thrown: (any Error)?
        do { try await task.value } catch { thrown = error }
        // 失败只携带退出码，不含命令输出（安全）。
        #expect((thrown as? PasswordSourceResolutionError) == .commandFailed(status: 3))
        #expect(await driver.connectCount == 0)
    }

    // MARK: - 原始配置不被解析出的密码污染

    @Test func connectKeepsOriginalConfigWithoutResolvedSecret() async throws {
        let (vm, driver) = await makeSUT()
        vm.passwordResolver = PasswordSourceResolver(environment: [:], readFile: { _ in "filepass\n" })
        let config = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .file, filePath: "/run/secrets/db"))
        await vm.connect(config: config)
        #expect(vm.isConnected)
        // 驱动拿到解析后的密码……
        #expect(await driver.lastConnectConfig?.password == "filepass")
        // ……但 selectedConfig 仍是原始来源配置，明文密码绝不写回。
        #expect(vm.selectedConfig?.password == nil)
        #expect(vm.selectedConfig?.passwordSource?.kind == .file)
        await vm.disconnect()
    }

    @Test func switchingConnectionCancelsPendingPrompt() async {
        let (vm, driver) = await makeSUT()
        let askConfig = makeConfig().withPasswordSource(ConnectionPasswordSource(kind: .askEveryTime))
        let taskA = Task { await vm.connect(config: askConfig) }
        #expect(await waitForPrompt(vm))
        // 第二条连接（默认 Keychain）开始：取消挂起的询问，A 中止、B 连上。
        let second = DatabaseConfig(name: "second", type: .mysql, host: "127.0.0.1", database: "testdb", username: "u", password: "stored")
        await vm.connect(config: second)
        await taskA.value
        #expect(vm.isConnected)
        #expect(vm.passwordPrompt == nil)
        #expect(await driver.lastConnectConfig?.name == "second")
        await vm.disconnect()
    }

    // MARK: - 续体只消费一次，重复 resolve 安全

    @Test func resolvePasswordPromptWithoutPendingIsSafe() async {
        let (vm, _) = await makeSUT()
        vm.resolvePasswordPrompt("stray")
        vm.resolvePasswordPrompt(nil)
        #expect(vm.passwordPrompt == nil)
    }

    @Test func resolveCommandConfirmationWithoutPendingIsSafe() async {
        let (vm, _) = await makeSUT()
        vm.resolveCommandConfirmation(true)
        vm.resolveCommandConfirmation(false)
        #expect(vm.commandConfirmation == nil)
    }
}