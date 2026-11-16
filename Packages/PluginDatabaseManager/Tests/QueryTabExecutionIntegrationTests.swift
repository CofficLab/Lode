@testable import DatabaseManagerPlugin
import Foundation
import Testing

// P3-2 多标签查询工作区验收：
// - 5 个标签各自执行互不串结果（结果按发起标签路由）；
// - 执行中途切标签：迟到结果落回发起标签快照，不污染当前活动标签；
// - 会话持久化往返（重启恢复文本/标题/活动标签）；
// - 脏标签关闭确认 + 最近关闭重开。

/// 标签查询的识别标记：含此片段的查询回显自身 SQL，便于断言结果归属。
private let tabMark = "tabmark"

/// 可控假连接：按 token 挂起查询（复现执行中途切标签），其余查询返回空结果，
/// 含 ``tabMark`` 的查询回显 SQL 作为结果行。
private actor TabConnection: DatabaseConnection {
    private var armed: Set<String> = []
    private var started: Set<String> = []
    private var released: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func armGate(_ token: String) { armed.insert(token) }

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        if let token = armed.first(where: { sql.contains($0) }) {
            started.insert(token)
            await withCheckedContinuation { continuation in
                if released.contains(token) {
                    continuation.resume()
                } else {
                    waiters[token] = continuation
                }
            }
        }
        if sql.contains(tabMark) {
            return QueryResult(columns: ["echo"], rows: [[.string(sql)]], rowsAffected: 1)
        }
        return QueryResult(columns: [], rows: [], rowsAffected: 0)
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
    func beginTransaction() async throws -> any DatabaseTransaction { TabTestTransaction() }
    func close() async {}
    func isAlive() async -> Bool { true }
    func cancel() async {}
    func isClosed() -> Bool { false }

    func waitUntilStarted(_ token: String) async {
        while !started.contains(token) { await Task.yield() }
    }

    func release(_ token: String) {
        released.insert(token)
        if let waiter = waiters.removeValue(forKey: token) { waiter.resume() }
    }
}

private struct TabTestTransaction: DatabaseTransaction {
    func commit() async throws {}
    func rollback() async throws {}
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
}

private actor TabDriver: DatabaseDriver {
    nonisolated let type: DatabaseType
    private let connection: TabConnection
    init(type: DatabaseType, connection: TabConnection) {
        self.type = type
        self.connection = connection
    }
    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection { connection }
}

@MainActor
@Suite(.serialized)
struct QueryTabExecutionIntegrationTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "lode-tab-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeSUT(defaults: UserDefaults) async -> (DatabaseViewModel, TabConnection) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let connection = TabConnection()
        await manager.register(driver: TabDriver(type: .sqlite, connection: connection))
        let vm = DatabaseViewModel(loadSavedConfigs: false, manager: manager, workspaceDefaults: defaults)
        return (vm, connection)
    }

    private func connect(_ vm: DatabaseViewModel) async {
        let config = DatabaseConfig(name: "tabs", type: .sqlite, database: "tabdb")
        await vm.connect(config: config)
    }

    private func echoContains(_ result: QueryResult?, _ needle: String) -> Bool {
        guard let row = result?.rows.first, let value = row.first else { return false }
        return value.description.contains(needle)
    }

    @Test("5 个标签各自执行互不串结果")
    func fiveTabsKeepIndependentResults() async {
        let defaults = makeDefaults()
        let (vm, _) = await makeSUT(defaults: defaults)
        await connect(vm)
        #expect(vm.isConnected)

        var ids: [UUID] = [vm.workspace.activeTabID]
        for i in 0..<5 {
            if i > 0 {
                vm.newQueryTab()
                ids.append(vm.workspace.activeTabID)
            }
            vm.queryText = "SELECT '\(tabMark)\(i)'"
            await vm.executeQuery()
            // 活动标签实时结果即本标签结果。
            #expect(echoContains(vm.queryResult, "\(tabMark)\(i)"))
        }

        // 每个标签快照都只含自己的结果。
        for (i, id) in ids.enumerated() {
            let tab = vm.workspace.tab(id: id)
            #expect(echoContains(tab?.result, "\(tabMark)\(i)"))
        }
        #expect(vm.workspace.tabs.count == 5)
    }

    @Test("执行中途切标签：迟到结果落回发起标签，不污染活动标签")
    func midFlightSwitchRoutesResultToOriginTab() async {
        let defaults = makeDefaults()
        let (vm, connection) = await makeSUT(defaults: defaults)
        await connect(vm)

        // 标签 A：发起一个被挂起的查询。
        let idA = vm.workspace.activeTabID
        vm.queryText = "SELECT '\(tabMark)A' /* gateA */"
        await connection.armGate("gateA")
        let flight = Task { await vm.executeQuery() }
        await connection.waitUntilStarted("gateA")
        #expect(vm.runningTabID == idA)

        // 查询仍挂在 A 上时切到 B（B 尚无结果）。
        vm.newQueryTab()
        let idB = vm.workspace.activeTabID
        #expect(idB != idA)
        vm.queryText = "SELECT '\(tabMark)B'"
        #expect(vm.queryResult == nil)

        // 放行 A：结果必须落回 A 快照，B 的实时状态保持空白。
        await connection.release("gateA")
        await flight.value

        #expect(vm.workspace.activeTabID == idB)
        #expect(vm.queryResult == nil)
        #expect(echoContains(vm.workspace.tab(id: idA)?.result, "\(tabMark)A"))
        #expect(vm.workspace.tab(id: idB)?.result == nil)
        #expect(vm.runningTabID == nil)
        #expect(vm.isLoading == false)

        // 切回 A 能看到自己的结果。
        vm.selectQueryTab(id: idA)
        #expect(echoContains(vm.queryResult, "\(tabMark)A"))
    }

    @Test("会话持久化往返：重启恢复文本/标题/活动标签")
    func workspaceRestoresAcrossRestart() async {
        let defaults = makeDefaults()
        let (vm, _) = await makeSUT(defaults: defaults)
        await connect(vm)

        let id1 = vm.workspace.activeTabID
        vm.queryText = "SELECT 1"
        vm.renameQueryTab(id: id1, title: "First")
        vm.newQueryTab()
        let id2 = vm.workspace.activeTabID
        vm.queryText = "SELECT 2"
        vm.newQueryTab()
        let id3 = vm.workspace.activeTabID
        vm.queryText = "SELECT 3"
        // 通过切换 flush 活动标签快照并落盘（确定性强，无需等待防抖）。
        vm.selectQueryTab(id: id1)
        vm.selectQueryTab(id: id3)

        // 模拟重启：同一 UserDefaults suite 新建 VM。
        let (vm2, _) = await makeSUT(defaults: defaults)
        #expect(vm2.workspace.loadedFromDisk)
        #expect(vm2.workspace.tabs.count == 3)
        #expect(vm2.workspace.activeTabID == id3)
        #expect(vm2.workspace.tab(id: id1)?.title == "First")
        #expect(vm2.workspace.tab(id: id1)?.text == "SELECT 1")
        #expect(vm2.workspace.tab(id: id2)?.text == "SELECT 2")
        #expect(vm2.workspace.tab(id: id3)?.text == "SELECT 3")
        // 活动标签文本已载入实时编辑器。
        #expect(vm2.queryText == "SELECT 3")
        // 结果不持久化：恢复后为空。
        #expect(vm2.queryResult == nil)
    }

    @Test("脏标签关闭需确认；确认后移除并可重开")
    func closeDirtyTabRequiresConfirmationAndReopen() async {
        let defaults = makeDefaults()
        let (vm, _) = await makeSUT(defaults: defaults)
        await connect(vm)

        let id1 = vm.workspace.activeTabID
        vm.queryText = "SELECT 'edited'"
        // 脏标签：关闭先弹确认，标签仍在。
        vm.closeQueryTab(id: id1)
        #expect(vm.pendingCloseTabID == id1)
        #expect(vm.workspace.tab(id: id1) != nil)

        vm.confirmClosePendingTab()
        #expect(vm.pendingCloseTabID == nil)
        #expect(vm.workspace.tab(id: id1) == nil)
        // 永不空：关掉最后一个会补一个新标签。
        #expect(vm.workspace.tabs.count == 1)

        // 重开最近关闭：文本恢复且脏标记复位。
        vm.reopenLastClosedTab()
        let reopened = vm.workspace.activeTabID
        #expect(vm.workspace.tab(id: reopened)?.text == "SELECT 'edited'")
        #expect(vm.workspace.isDirty(id: reopened) == false)
        #expect(vm.queryText == "SELECT 'edited'")
    }
}