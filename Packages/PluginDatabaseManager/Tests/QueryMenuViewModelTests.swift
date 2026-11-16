import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P6-5a 离线单测（@MainActor VM，注入 UserDefaults 隔离）：
// 标签循环切换（下一个/上一个/按位置 ⌘1…⌘9）+ 越界与单标签守卫 + 切换保留编辑文本；
// QueryMenuActions 闭包转发与门控标志逐一对应。

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct QueryMenuViewModelTests {
    private func makeSuite() -> String { "lode-querymenu-\(UUID().uuidString)" }

    private func cleanup(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func makeSUT(_ suite: String) async -> DatabaseViewModel {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        return DatabaseViewModel(loadSavedConfigs: false, manager: manager, workspaceDefaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: - 标签切换

    @Test func nextTabCyclesForward() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.newQueryTab()
        vm.newQueryTab()
        #expect(vm.workspace.tabs.count == 3)
        vm.selectQueryTab(index: 2)
        #expect(vm.workspace.activeIndex == 2)
        vm.selectNextQueryTab()
        #expect(vm.workspace.activeIndex == 0)
    }

    @Test func previousTabCyclesBackward() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.newQueryTab()
        vm.newQueryTab()
        vm.selectQueryTab(index: 0)
        vm.selectPreviousQueryTab()
        #expect(vm.workspace.activeIndex == 2)
        vm.selectPreviousQueryTab()
        #expect(vm.workspace.activeIndex == 1)
    }

    @Test func selectTabByIndexActivatesAndAppliesText() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.queryText = "SELECT 1"
        vm.newQueryTab()
        vm.queryText = "SELECT 2"
        vm.selectQueryTab(index: 0)
        #expect(vm.workspace.activeIndex == 0)
        #expect(vm.queryText == "SELECT 1")
        vm.selectQueryTab(index: 1)
        #expect(vm.queryText == "SELECT 2")
    }

    @Test func selectTabOutOfRangeIsIgnored() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.newQueryTab()
        let active = vm.workspace.activeTabID
        vm.selectQueryTab(index: 9)
        vm.selectQueryTab(index: -1)
        #expect(vm.workspace.activeTabID == active)
    }

    @Test func singleTabNextPreviousAreNoOps() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        #expect(vm.workspace.tabs.count == 1)
        let active = vm.workspace.activeTabID
        vm.selectNextQueryTab()
        vm.selectPreviousQueryTab()
        #expect(vm.workspace.activeTabID == active)
    }

    @Test func tabSwitchPreservesUnsavedText() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.queryText = "SELECT 'first'"
        vm.newQueryTab()
        vm.queryText = "SELECT 'second'"
        vm.selectNextQueryTab()
        #expect(vm.queryText == "SELECT 'first'")
        vm.selectNextQueryTab()
        #expect(vm.queryText == "SELECT 'second'")
    }

    // MARK: - 菜单动作接线

    @Test func menuActionsForwardCallsAndFlags() {
        var calls: [String: Int] = [:]
        func spy(_ name: String) -> () -> Void {
            { calls[name, default: 0] += 1 }
        }
        var selectedIndex: Int?
        let actions = QueryMenuActions(
            run: spy("run"),
            runAll: spy("runAll"),
            stop: spy("stop"),
            format: spy("format"),
            explain: spy("explain"),
            showHistory: spy("showHistory"),
            newTab: spy("newTab"),
            closeTab: spy("closeTab"),
            reopenClosedTab: spy("reopenClosedTab"),
            nextTab: spy("nextTab"),
            previousTab: spy("previousTab"),
            selectTab: { selectedIndex = $0 },
            commitChanges: spy("commitChanges"),
            toggleFilter: spy("toggleFilter"),
            canRun: true,
            canStop: false,
            canFormat: true,
            canExplain: false,
            canManageTabs: true,
            canReopenClosedTab: false,
            tabCount: 3,
            canCommitChanges: false,
            canToggleFilter: true
        )
        actions.run()
        actions.runAll()
        actions.stop()
        actions.format()
        actions.explain()
        actions.showHistory()
        actions.newTab()
        actions.closeTab()
        actions.reopenClosedTab()
        actions.nextTab()
        actions.previousTab()
        actions.selectTab(2)
        actions.commitChanges()
        actions.toggleFilter()
        let expected = [
            "run", "runAll", "stop", "format", "explain", "showHistory",
            "newTab", "closeTab", "reopenClosedTab", "nextTab", "previousTab",
            "commitChanges", "toggleFilter",
        ]
        for name in expected {
            #expect(calls[name] == 1, "\(name) forwarded exactly once")
        }
        #expect(selectedIndex == 2)
        #expect(actions.canRun)
        #expect(!actions.canStop)
        #expect(actions.canFormat)
        #expect(!actions.canExplain)
        #expect(actions.canManageTabs)
        #expect(!actions.canReopenClosedTab)
        #expect(actions.tabCount == 3)
        #expect(!actions.canCommitChanges)
        #expect(actions.canToggleFilter)
    }
}