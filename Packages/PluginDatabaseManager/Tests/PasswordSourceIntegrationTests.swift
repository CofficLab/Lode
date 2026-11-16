import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P4-7 真实引擎验收：密码来源端到端。
// 内联密码故意填错（"wrong-inline"），只有来源解析出的正确密码（"test"）才能连上真实 PG，
// 以此证明驱动拿到的是「解析后的密码」而非内联值。command 走真实 /bin/sh 执行器。
//
// 需本地 Docker：设置 LODE_TEST_PG_PORT 后启用。

private func p47Port(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct PasswordSourceIntegrationTests {
    private func makeSUT() async -> DatabaseViewModel {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        return DatabaseViewModel(loadSavedConfigs: false, manager: manager)
    }

    /// 内联密码故意错误；正确密码只能来自来源解析。
    private func pgConfig(port: Int, source: ConnectionPasswordSource) -> DatabaseConfig {
        DatabaseConfig(name: "p47", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "wrong-inline")
            .withSafeMode(.off)
            .withPasswordSource(source)
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

    @Test(.enabled(if: p47Port("LODE_TEST_PG_PORT") != nil))
    func pgEnvironmentSourceConnects() async throws {
        let port = try #require(p47Port("LODE_TEST_PG_PORT"))
        let vm = await makeSUT()
        vm.passwordResolver = PasswordSourceResolver(environment: ["LODE_TEST_PG_PASSWORD": "test"])
        let config = pgConfig(port: port, source: ConnectionPasswordSource(kind: .environment, variableName: "LODE_TEST_PG_PASSWORD"))
        await vm.connect(config: config)
        defer { Task { await vm.disconnect() } }
        #expect(vm.isConnected)
        // 原始配置不被解析出的密码污染。
        #expect(vm.selectedConfig?.password == "wrong-inline")
    }

    @Test(.enabled(if: p47Port("LODE_TEST_PG_PORT") != nil))
    func pgFileSourceConnects() async throws {
        let port = try #require(p47Port("LODE_TEST_PG_PORT"))
        let path = NSTemporaryDirectory() + "lode-p47-\(UUID().uuidString).pw"
        try "test\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let vm = await makeSUT()
        let config = pgConfig(port: port, source: ConnectionPasswordSource(kind: .file, filePath: path))
        await vm.connect(config: config)
        defer { Task { await vm.disconnect() } }
        #expect(vm.isConnected)
    }

    @Test(.enabled(if: p47Port("LODE_TEST_PG_PORT") != nil))
    func pgAskEveryTimeConnectsViaPrompt() async throws {
        let port = try #require(p47Port("LODE_TEST_PG_PORT"))
        let vm = await makeSUT()
        let config = pgConfig(port: port, source: ConnectionPasswordSource(kind: .askEveryTime))
        let task = Task { await vm.connect(config: config) }
        #expect(await waitForPrompt(vm))
        vm.resolvePasswordPrompt("test")
        await task.value
        defer { Task { await vm.disconnect() } }
        #expect(vm.isConnected)
        #expect(vm.passwordPrompt == nil)
    }

    @Test(.enabled(if: p47Port("LODE_TEST_PG_PORT") != nil))
    func pgCommandSourceConnectsViaConfirmation() async throws {
        let port = try #require(p47Port("LODE_TEST_PG_PORT"))
        let vm = await makeSUT()
        // 真实 /bin/sh 执行器：echo 输出带尾换行，解析器去掉后得到 "test"。
        let config = pgConfig(port: port, source: ConnectionPasswordSource(kind: .command, command: "echo test"))
        let task = Task { await vm.connect(config: config) }
        #expect(await waitForCommandConfirmation(vm))
        vm.resolveCommandConfirmation(true)
        await task.value
        defer { Task { await vm.disconnect() } }
        #expect(vm.isConnected)
        #expect(vm.commandConfirmation == nil)
    }
}