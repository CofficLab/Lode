import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P6-2a 离线单测：片段占位符展开器（默认值/转义/未闭合/UTF-16 选区）+
// 收藏查询与片段存储 JSON 往返（注入 UserDefaults 隔离，跨重开持久）。

@Suite(.serialized)
struct SavedQueryTests {
    private func makeSuite() -> String { "lode-saved-\(UUID().uuidString)" }

    private func cleanup(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    // MARK: - SnippetExpander

    @Test func expandPlainTextUnchanged() {
        let result = SnippetExpander.expansion("SELECT 1")
        #expect(result.text == "SELECT 1")
        #expect(result.firstSelection == nil)
        #expect(SnippetExpander.placeholders("SELECT 1").isEmpty)
    }

    @Test func expandPlaceholderWithoutDefaultIsEmpty() {
        #expect(SnippetExpander.expand("SELECT * FROM ${table}") == "SELECT * FROM ")
        #expect(SnippetExpander.placeholders("SELECT * FROM ${table}") == [SnippetPlaceholder(name: "table", defaultValue: "")])
    }

    @Test func expandWithDefaultsAndFirstSelection() {
        let result = SnippetExpander.expansion("SELECT * FROM ${table:users} WHERE id=${id:1}")
        #expect(result.text == "SELECT * FROM users WHERE id=1")
        #expect(result.firstSelection == NSRange(location: 14, length: 5))
    }

    @Test func defaultValueMayContainColon() {
        #expect(SnippetExpander.expand("${a:x:y}") == "x:y")
        #expect(SnippetExpander.placeholders("${a:x:y}") == [SnippetPlaceholder(name: "a", defaultValue: "x:y")])
    }

    @Test func escapedDollarProducesLiteralPlaceholder() {
        #expect(SnippetExpander.expand("$${table}") == "${table}")
        #expect(SnippetExpander.placeholders("$${table}").isEmpty)
    }

    @Test func doubleDollarEscapesToSingle() {
        #expect(SnippetExpander.expand("cost $$5") == "cost $5")
    }

    @Test func unclosedBraceIsLiteral() {
        #expect(SnippetExpander.expand("SELECT ${oops") == "SELECT ${oops")
        #expect(SnippetExpander.placeholders("SELECT ${oops").isEmpty)
    }

    @Test func placeholdersKeepOrderAndDuplicates() {
        let placeholders = SnippetExpander.placeholders("${a:1}${b}${a:2}")
        #expect(placeholders == [
            SnippetPlaceholder(name: "a", defaultValue: "1"),
            SnippetPlaceholder(name: "b", defaultValue: ""),
            SnippetPlaceholder(name: "a", defaultValue: "2"),
        ])
        #expect(SnippetExpander.expand("${a:1}${b}${a:2}") == "12")
    }

    @Test func firstSelectionUsesUTF16AfterEmoji() {
        let result = SnippetExpander.expansion("😀${x:ab}")
        #expect(result.text == "😀ab")
        #expect(result.firstSelection == NSRange(location: 2, length: 2))
    }

    @Test func firstSelectionSkipsEmptyDefault() {
        let result = SnippetExpander.expansion("${a}${b:z}")
        #expect(result.text == "z")
        #expect(result.firstSelection == NSRange(location: 0, length: 1))
    }

    @Test func emptyBodyExpandsToEmpty() {
        let result = SnippetExpander.expansion("")
        #expect(result.text == "")
        #expect(result.firstSelection == nil)
    }

    // MARK: - SavedQueryStore

    @Test func queriesRoundTripAndPersistAcrossReopen() {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let store = SavedQueryStore(defaults: defaults)
        let queries = [
            SavedQuery(name: "Active users", sql: "SELECT * FROM users WHERE active=1", configName: "prod", database: "app"),
            SavedQuery(name: "Count", sql: "SELECT COUNT(*) FROM logs", configName: "prod"),
        ]
        store.saveQueries(queries)
        #expect(store.loadQueries() == queries)
        let reopened = SavedQueryStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(reopened.loadQueries() == queries)
    }

    @Test func snippetsRoundTrip() {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let store = SavedQueryStore(defaults: UserDefaults(suiteName: suite)!)
        let snippets = [
            Snippet(name: "select", body: "SELECT * FROM ${table:users}"),
            Snippet(name: "insert", body: "INSERT INTO ${table} (${cols}) VALUES (${vals})"),
        ]
        store.saveSnippets(snippets)
        #expect(store.loadSnippets() == snippets)
    }

    @Test func emptyStoreReturnsEmptyArrays() {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let store = SavedQueryStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(store.loadQueries().isEmpty)
        #expect(store.loadSnippets().isEmpty)
    }

    @Test func saveOverwritesPrevious() {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let store = SavedQueryStore(defaults: UserDefaults(suiteName: suite)!)
        store.saveQueries([SavedQuery(name: "a", sql: "SELECT 1", configName: "c")])
        store.saveQueries([SavedQuery(name: "b", sql: "SELECT 2", configName: "c")])
        let loaded = store.loadQueries()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "b")
    }

    @Test func queriesAndSnippetsUseIndependentKeys() {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let store = SavedQueryStore(defaults: UserDefaults(suiteName: suite)!)
        store.saveQueries([SavedQuery(name: "q", sql: "SELECT 1", configName: "c")])
        store.saveSnippets([Snippet(name: "s", body: "SELECT 2")])
        store.saveQueries([])
        #expect(store.loadQueries().isEmpty)
        #expect(store.loadSnippets().count == 1)
    }

    @Test func savedQueryCodableRoundTrip() throws {
        let query = SavedQuery(name: "n", sql: "SELECT '中文'", configName: "c", database: "d")
        let data = try JSONEncoder().encode(query)
        let decoded = try JSONDecoder().decode(SavedQuery.self, from: data)
        #expect(decoded == query)
    }
}