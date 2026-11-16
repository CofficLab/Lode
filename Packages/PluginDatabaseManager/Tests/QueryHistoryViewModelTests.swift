import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P6-1b VM 接线离线单测：pin 刷新置顶优先、保留期联动清理与 published 同步、
// 重执行载入文本并关闭面板、删除尊重当前搜索上下文。注入独立 FTS5 store 与 suite 避免串扰。

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct QueryHistoryViewModelTests {
    private func makeSUT(oldEntries: [QueryHistoryEntry] = []) async -> (DatabaseViewModel, QueryHistoryStore, URL, String) {
        let suite = "lode-histvm-test-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lode-histvm-\(UUID().uuidString).sqlite")
        if !oldEntries.isEmpty, let data = try? JSONEncoder().encode(oldEntries) {
            UserDefaults(suiteName: suite)?.set(data, forKey: "DatabaseManager.queryHistory")
        }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let vm = DatabaseViewModel(
            loadSavedConfigs: false, manager: manager,
            workspaceDefaults: UserDefaults(suiteName: suite)!, historyStore: store)
        return (vm, store, url, suite)
    }

    private func cleanup(url: URL, suite: String) {
        try? FileManager.default.removeItem(at: url)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func togglePinRefreshesHistoryPinnedFirst() async throws {
        let (vm, store, url, suite) = await makeSUT(); defer { cleanup(url: url, suite: suite) }
        await store.record(sql: "SELECT older", configName: "c", database: "d")
        await store.record(sql: "SELECT newer", configName: "c", database: "d")
        await vm.loadRecentHistory()
        let older = try #require(vm.history.first { $0.sql == "SELECT older" })
        await vm.togglePinHistoryEntry(older)
        #expect(vm.history.first?.sql == "SELECT older")
        #expect(vm.history.first?.pinned == true)
        let pinned = try #require(vm.history.first { $0.sql == "SELECT older" })
        await vm.togglePinHistoryEntry(pinned)
        #expect(vm.history.first?.pinned == false)
    }

    @Test func setRetentionDaysPrunesOldAndUpdatesPublished() async throws {
        let old = QueryHistoryEntry(sql: "SELECT ancient", configName: "c", database: "d",
                                    executedAt: Date().addingTimeInterval(-40 * 86400))
        let (vm, _, url, suite) = await makeSUT(oldEntries: [old]); defer { cleanup(url: url, suite: suite) }
        await vm.loadRecentHistory()
        #expect(vm.history.count == 1)
        #expect(vm.historyRetentionDays == 0)
        await vm.setHistoryRetentionDays(30)
        #expect(vm.historyRetentionDays == 30)
        #expect(vm.history.isEmpty)
    }

    @Test func reRunLoadsQueryTextAndClosesPanel() async throws {
        let (vm, store, url, suite) = await makeSUT(); defer { cleanup(url: url, suite: suite) }
        await store.record(sql: "SELECT 42", configName: "c", database: "d")
        await vm.loadRecentHistory()
        let entry = try #require(vm.history.first)
        vm.showHistory = true
        await vm.reRunHistoryEntry(entry)
        #expect(vm.queryText == "SELECT 42")
        #expect(vm.showHistory == false)
    }

    @Test func deleteRespectsSearchContext() async throws {
        let (vm, store, url, suite) = await makeSUT(); defer { cleanup(url: url, suite: suite) }
        await store.record(sql: "SELECT alpha", configName: "c", database: "d")
        await store.record(sql: "SELECT beta", configName: "c", database: "d")
        await vm.searchHistory("alpha")
        #expect(vm.history.count == 1)
        let entry = try #require(vm.history.first)
        await vm.deleteHistoryEntry(entry)
        #expect(vm.history.isEmpty)
        #expect(vm.historySearchText == "alpha")
    }
}