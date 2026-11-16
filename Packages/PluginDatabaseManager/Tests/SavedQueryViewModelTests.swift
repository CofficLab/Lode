import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P6-2b 离线单测（@MainActor VM，注入 UserDefaults 隔离）：
// 收藏查询 CRUD + 按连接过滤 + 同名替换 + 跨重开持久；片段增删 + 光标插入展开与选区。

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SavedQueryViewModelTests {
    private func makeSuite() -> String { "lode-savedvm-\(UUID().uuidString)" }

    private func cleanup(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func makeSUT(_ suite: String) async -> DatabaseViewModel {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        return DatabaseViewModel(loadSavedConfigs: false, manager: manager, workspaceDefaults: UserDefaults(suiteName: suite)!)
    }

    private func config(_ name: String) -> DatabaseConfig {
        DatabaseConfig(name: name, type: .sqlite, database: ":memory:")
    }

    // MARK: - 收藏查询

    @Test func saveCurrentQueryFiltersByConnection() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.selectedConfig = config("prod")
        vm.queryText = "SELECT 1"
        vm.saveCurrentQuery(name: "Q1")
        #expect(vm.savedQueries.count == 1)
        #expect(vm.savedQueries.first?.configName == "prod")
        #expect(vm.currentConnectionSavedQueries.count == 1)
        vm.selectedConfig = config("other")
        #expect(vm.currentConnectionSavedQueries.isEmpty)
    }

    @Test func saveCurrentQueryReplacesSameNameSameConnection() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.selectedConfig = config("prod")
        vm.queryText = "SELECT 1"
        vm.saveCurrentQuery(name: "Q1")
        vm.queryText = "SELECT 2"
        vm.saveCurrentQuery(name: "Q1")
        #expect(vm.savedQueries.count == 1)
        #expect(vm.savedQueries.first?.sql == "SELECT 2")
    }

    @Test func saveCurrentQueryIgnoresEmptyNameOrSQL() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.selectedConfig = config("prod")
        vm.queryText = "SELECT 1"
        vm.saveCurrentQuery(name: "   ")
        vm.queryText = "   "
        vm.saveCurrentQuery(name: "Q1")
        #expect(vm.savedQueries.isEmpty)
    }

    @Test func savedQueriesPersistAcrossReopen() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let first = await makeSUT(suite)
        first.selectedConfig = config("prod")
        first.queryText = "SELECT 42"
        first.saveCurrentQuery(name: "Answer")
        let second = await makeSUT(suite)
        #expect(second.savedQueries.count == 1)
        #expect(second.savedQueries.first?.name == "Answer")
        #expect(second.savedQueries.first?.sql == "SELECT 42")
    }

    @Test func loadRenameDeleteSavedQuery() async throws {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.selectedConfig = config("prod")
        vm.queryText = "SELECT 1"
        vm.saveCurrentQuery(name: "Q1")
        let query = try #require(vm.savedQueries.first)
        vm.queryText = ""
        vm.loadSavedQuery(query)
        #expect(vm.queryText == "SELECT 1")
        vm.renameSavedQuery(id: query.id, name: "Renamed")
        #expect(vm.savedQueries.first?.name == "Renamed")
        vm.renameSavedQuery(id: query.id, name: "  ")
        #expect(vm.savedQueries.first?.name == "Renamed")
        vm.deleteSavedQuery(query)
        #expect(vm.savedQueries.isEmpty)
    }

    // MARK: - 片段

    @Test func addSnippetDedupByNameAndDelete() async throws {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.addSnippet(name: "sel", body: "SELECT 1")
        vm.addSnippet(name: "sel", body: "SELECT 2")
        #expect(vm.snippets.count == 1)
        #expect(vm.snippets.first?.body == "SELECT 2")
        vm.addSnippet(name: "  ", body: "SELECT 3")
        #expect(vm.snippets.count == 1)
        let snippet = try #require(vm.snippets.first)
        vm.deleteSnippet(snippet)
        #expect(vm.snippets.isEmpty)
    }

    @Test func insertSnippetAtCursorExpandsAndSelectsDefault() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.queryText = "SELECT * FROM "
        vm.editorCursorLocation = (vm.queryText as NSString).length
        vm.editorSelectionRange = NSRange(location: NSNotFound, length: 0)
        vm.insertSnippet(Snippet(name: "t", body: "${table:users}"))
        #expect(vm.queryText == "SELECT * FROM users")
        #expect(vm.editorSelectionRange == NSRange(location: 14, length: 5))
    }

    @Test func insertSnippetReplacesSelection() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.queryText = "ABC"
        vm.editorCursorLocation = 1
        vm.editorSelectionRange = NSRange(location: 1, length: 1)
        vm.insertSnippet(Snippet(name: "t", body: "X${v:Y}Z"))
        #expect(vm.queryText == "AXYZC")
        #expect(vm.editorSelectionRange == NSRange(location: 2, length: 1))
    }

    @Test func insertSnippetAppendsWhenCursorUnknown() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.queryText = "AB"
        vm.editorCursorLocation = NSNotFound
        vm.editorSelectionRange = NSRange(location: NSNotFound, length: 0)
        vm.insertSnippet(Snippet(name: "t", body: "C"))
        #expect(vm.queryText == "ABC")
        #expect(vm.editorCursorLocation == 3)
        #expect(vm.editorSelectionRange == NSRange(location: 3, length: 0))
    }

    @Test func insertSnippetWithoutPlaceholderLeavesCursorAtEnd() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.queryText = ""
        vm.editorCursorLocation = 0
        vm.editorSelectionRange = NSRange(location: 0, length: 0)
        vm.insertSnippet(Snippet(name: "t", body: "SELECT 1"))
        #expect(vm.queryText == "SELECT 1")
        #expect(vm.editorCursorLocation == 8)
        #expect(vm.editorSelectionRange == NSRange(location: 8, length: 0))
    }
}