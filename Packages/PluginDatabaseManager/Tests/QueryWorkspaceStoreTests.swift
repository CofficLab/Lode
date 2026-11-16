import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-2 标签工作区状态机：新建/关闭/重命名/切换/重开/脏标记/持久化往返。

@MainActor
@Suite
struct QueryWorkspaceStoreTests {
    private func makeStore() -> QueryWorkspaceStore {
        let suite = "test.workspace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return QueryWorkspaceStore(defaults: defaults, loadPersisted: false)
    }

    @Test func newTabInsertsAfterActiveAndActivates() {
        let store = makeStore()
        let a = store.newTab(title: "A")
        let b = store.newTab(title: "B")
        #expect(store.tabs.map(\.title) == ["A", "B"])
        #expect(store.activeTabID == b)
        store.selectTab(id: a)
        let c = store.newTab(title: "C")
        #expect(store.tabs.map(\.title) == ["A", "C", "B"])
        #expect(store.activeTabID == c)
    }

    @Test func selectTabSwitchesActive() {
        let store = makeStore()
        let a = store.newTab(title: "A")
        let b = store.newTab(title: "B")
        #expect(store.activeTabID == b)
        store.selectTab(id: a)
        #expect(store.activeTabID == a)
        #expect(store.activeTab.title == "A")
        store.selectTab(id: UUID()) // 不存在 → 不变
        #expect(store.activeTabID == a)
    }

    @Test func closeActiveActivatesNeighbor() {
        let store = makeStore()
        let a = store.newTab(title: "A")
        let b = store.newTab(title: "B")
        let c = store.newTab(title: "C")
        store.selectTab(id: b)
        let newActive = store.closeTab(id: b)
        #expect(store.tabs.map(\.title) == ["A", "C"])
        #expect(newActive == c) // 关闭中间标签 → 激活原位置的后一个
        #expect(store.recentlyClosed.first?.id == b)
        store.selectTab(id: a)
        store.closeTab(id: a)
        #expect(store.activeTabID == c)
    }

    @Test func closeLastTabCreatesFresh() {
        let store = makeStore()
        let a = store.newTab(title: "A")
        store.closeTab(id: a)
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].id != a)
        #expect(store.activeTabID == store.tabs[0].id)
    }

    @Test func renameTrimsAndKeepsOnEmpty() {
        let store = makeStore()
        let a = store.newTab(title: "A")
        store.renameTab(id: a, title: "  Reports  ")
        #expect(store.tab(id: a)?.title == "Reports")
        store.renameTab(id: a, title: "   ")
        #expect(store.tab(id: a)?.title == "Reports")
    }

    @Test func reopenLastClosedRestoresTab() {
        let store = makeStore()
        let a = store.newTab(title: "A", text: "SELECT 1")
        store.newTab(title: "B")
        store.closeTab(id: a)
        #expect(store.tabs.map(\.title) == ["B"])
        let reopened = store.reopenLastClosed()
        #expect(reopened?.id == a)
        #expect(reopened?.text == "SELECT 1")
        #expect(store.activeTabID == a)
        #expect(store.recentlyClosed.isEmpty)
        #expect(store.reopenLastClosed() == nil)
    }

    @Test func dirtyTracksUnsavedText() {
        let store = makeStore()
        let a = store.newTab(title: "A", text: "SELECT 1")
        #expect(!store.isDirty(id: a)) // 新建即保存基线
        store.mutateTab(id: a) { $0.text = "SELECT 2" }
        #expect(store.isDirty(id: a))
        store.markSaved(id: a)
        #expect(!store.isDirty(id: a))
    }

    @Test func mutateTabRoutesToCorrectSnapshot() {
        let store = makeStore()
        let a = store.newTab(title: "A")
        let b = store.newTab(title: "B")
        store.selectTab(id: a)
        // 模拟迟到的执行结果路由到非活动标签 b。
        store.mutateTab(id: b) { $0.result = QueryResult(columns: ["x"], rows: [[.integer(1)]], rowsAffected: 1) }
        #expect(store.tab(id: b)?.result?.columns == ["x"])
        #expect(store.tab(id: a)?.result == nil)
        #expect(store.activeTab.result == nil)
    }

    @Test func persistenceRoundTrip() {
        let suite = "test.workspace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = QueryWorkspaceStore(defaults: defaults, loadPersisted: false)
        let a = store.newTab(title: "A", text: "SELECT 1")
        store.mutateTab(id: a) { $0.cursorLocation = 5 }
        let b = store.newTab(title: "B", text: "SELECT 2")
        store.selectTab(id: b)
        store.persist()

        let restored = QueryWorkspaceStore(defaults: defaults, loadPersisted: true)
        #expect(restored.tabs.map(\.title) == ["A", "B"])
        #expect(restored.tabs.map(\.text) == ["SELECT 1", "SELECT 2"])
        #expect(restored.activeTabID == b)
        #expect(restored.tab(id: a)?.cursorLocation == 5)
        #expect(restored.tabs.allSatisfy { !$0.isDirty }) // 恢复后基线即文本
        #expect(restored.tabs.allSatisfy { $0.result == nil }) // 结果不落盘
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func loadPersistedSeedsDefaultTabWhenEmpty() {
        let suite = "test.workspace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = QueryWorkspaceStore(defaults: defaults, loadPersisted: true)
        #expect(store.tabs.count == 1)
        #expect(store.activeTabID == store.tabs[0].id)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func recentlyClosedCapped() {
        let store = makeStore()
        var ids: [UUID] = []
        for i in 0..<12 {
            let id = store.newTab(title: "T\(i)")
            ids.append(id)
        }
        for id in ids { store.closeTab(id: id) }
        #expect(store.recentlyClosed.count == 10)
        // 最近关闭的在最前（最后一个关闭的 T11）。
        #expect(store.recentlyClosed.first?.title == "T11")
    }

    @Test func autoTitlePreview() {
        #expect(QueryTab.autoTitle(for: "SELECT * FROM users", fallback: "Query") == "SELECT * FROM users")
        #expect(QueryTab.autoTitle(for: "  \n ", fallback: "Query") == "Query")
        let long = String(repeating: "a", count: 40)
        #expect(QueryTab.autoTitle(for: long, fallback: "Query") == String(repeating: "a", count: 24) + "…")
    }
}