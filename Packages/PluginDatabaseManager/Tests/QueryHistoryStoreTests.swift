import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P6-1a 离线单测：SQLite FTS5 历史存储——迁移往返、全文搜索、敏感过滤不回归、
// 保留期/数量上限清理（置顶豁免）、pin 排序与去重保留、重开持久化、MATCH 整形。

private struct LegacyEntry: Codable {
    let id: UUID
    let sql: String
    let configName: String
    let database: String
    let executedAt: Date
}

@Suite(.serialized)
struct QueryHistoryStoreTests {
    private func makeSuite() -> String { "lode-history-test-\(UUID().uuidString)" }
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lode-history-\(UUID().uuidString).sqlite")
    }
    private func cleanup(url: URL, suite: String) {
        try? FileManager.default.removeItem(at: url)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    private func seedLegacy(suite: String, _ entries: [LegacyEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        UserDefaults(suiteName: suite)?.set(data, forKey: "DatabaseManager.queryHistory")
    }
    private func legacy(_ sql: String, daysAgo: Double, id: UUID = UUID()) -> LegacyEntry {
        LegacyEntry(id: id, sql: sql, configName: "conn", database: "db",
                    executedAt: Date().addingTimeInterval(-daysAgo * 86400))
    }

    // MARK: - 记录 / 去重 / 敏感过滤

    @Test func recordAndRecentRoundTrip() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "SELECT 1", configName: "c", database: "d")
        await store.record(sql: "SELECT 2", configName: "c", database: "d")
        await store.record(sql: "SELECT 3", configName: "c", database: "d")
        let recent = await store.recent(limit: 10)
        #expect(recent.count == 3)
        #expect(Set(recent.map(\.sql)) == ["SELECT 1", "SELECT 2", "SELECT 3"])
        #expect(recent.allSatisfy { $0.configName == "c" && $0.database == "d" && !$0.pinned })
    }

    @Test func dedupKeepsSingleEntry() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "SELECT 1", configName: "c", database: "d")
        await store.record(sql: "SELECT 1", configName: "c", database: "d")
        #expect(await store.count() == 1)
        #expect(await store.recent(limit: 10).first?.sql == "SELECT 1")
    }

    @Test func sensitiveStatementsAreNotRecorded() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "CREATE USER x IDENTIFIED BY 'secret'", configName: "c", database: "d")
        await store.record(sql: "SET PASSWORD FOR x = 'secret'", configName: "c", database: "d")
        await store.record(sql: "ALTER ROLE r WITH PASSWORD 'secret'", configName: "c", database: "d")
        await store.record(sql: "DROP USER x", configName: "c", database: "d")
        await store.record(sql: "SELECT 1", configName: "c", database: "d")
        #expect(await store.count() == 1)
        #expect(await store.recent(limit: 10).first?.sql == "SELECT 1")
    }

    @Test func emptyAndWhitespaceNotRecorded() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "", configName: "c", database: "d")
        await store.record(sql: "   ", configName: "c", database: "d")
        await store.record(sql: "\n\t", configName: "c", database: "d")
        #expect(await store.count() == 0)
    }

    // MARK: - 全文搜索

    @Test func ftsSearchMatchesTokensAndPrefix() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "SELECT * FROM users", configName: "c", database: "d")
        await store.record(sql: "SELECT * FROM orders", configName: "c", database: "d")
        await store.record(sql: "INSERT INTO logs VALUES (1)", configName: "c", database: "d")

        let users = await store.search("users")
        #expect(users.count == 1)
        #expect(users.first?.sql == "SELECT * FROM users")
        #expect(await store.search("SELECT").count == 2)
        #expect(await store.search("ord").first?.sql == "SELECT * FROM orders")
        #expect(await store.search("logs").count == 1)
        #expect(await store.search("nonexistentxyz").isEmpty)
        // 多词 AND：同时含 FROM 与 users 才命中。
        #expect(await store.search("FROM users").count == 1)
        #expect(await store.search("FROM logs").isEmpty)
    }

    @Test func searchEmptyReturnsAll() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "SELECT 1", configName: "c", database: "d")
        await store.record(sql: "SELECT 2", configName: "c", database: "d")
        #expect(await store.search("").count == 2)
        #expect(await store.search("   ").count == 2)
    }

    @Test func searchPunctuationOnlyIsSafe() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "SELECT 1", configName: "c", database: "d")
        // 纯标点不触发 FTS5 语法错误，退回全部。
        #expect(await store.search("\"").count == 1)
        #expect(await store.search("*").count == 1)
        #expect(await store.search("()").count == 1)
    }

    @Test func searchMatchesCJK() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "SELECT '中文' FROM t", configName: "c", database: "d")
        #expect(await store.search("中文").count == 1)
    }

    @Test func ftsMatchQueryShaping() {
        #expect(QueryHistoryStore.ftsMatchQuery("users") == "\"users\"*")
        #expect(QueryHistoryStore.ftsMatchQuery("FROM users") == "\"FROM\"* \"users\"*")
        #expect(QueryHistoryStore.ftsMatchQuery("a\"b") == "\"a\"\"b\"*")
        #expect(QueryHistoryStore.ftsMatchQuery("") == nil)
        #expect(QueryHistoryStore.ftsMatchQuery("   ") == nil)
        #expect(QueryHistoryStore.ftsMatchQuery("***") == nil)
    }

    // MARK: - 迁移

    @Test func migrationImportsLegacyAndClearsKey() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        try seedLegacy(suite: suite, [legacy("SELECT legacy", daysAgo: 1)])
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        let recent = await store.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.sql == "SELECT legacy")
        // 旧格式无 pinned 字段，解码缺省 false。
        #expect(recent.first?.pinned == false)
        #expect(UserDefaults(suiteName: suite)?.data(forKey: "DatabaseManager.queryHistory") == nil)
    }

    @Test func migrationSkipsSensitiveLegacy() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        try seedLegacy(suite: suite, [legacy("CREATE USER x IDENTIFIED BY 'p'", daysAgo: 1), legacy("SELECT ok", daysAgo: 1)])
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        #expect(await store.count() == 1)
        #expect(await store.recent(limit: 10).first?.sql == "SELECT ok")
    }

    // MARK: - pin / 删除 / 清空

    @Test func pinSortsFirst() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let older = UUID()
        try seedLegacy(suite: suite, [legacy("SELECT older", daysAgo: 2, id: older), legacy("SELECT newer", daysAgo: 1)])
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        #expect(await store.recent(limit: 10).first?.sql == "SELECT newer")
        await store.setPinned(id: older, pinned: true)
        let recent = await store.recent(limit: 10)
        #expect(recent.first?.sql == "SELECT older")
        #expect(recent.first?.pinned == true)
        await store.setPinned(id: older, pinned: false)
        #expect(await store.recent(limit: 10).first?.sql == "SELECT newer")
    }

    @Test func deleteRemovesEntry() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "SELECT a", configName: "c", database: "d")
        await store.record(sql: "SELECT b", configName: "c", database: "d")
        let target = await store.recent(limit: 10).first { $0.sql == "SELECT a" }
        let id = try #require(target?.id)
        await store.delete(id: id)
        #expect(await store.count() == 1)
        #expect(await store.recent(limit: 10).first?.sql == "SELECT b")
    }

    @Test func clearRemovesAllIncludingPinned() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let pinnedID = UUID()
        try seedLegacy(suite: suite, [legacy("SELECT p", daysAgo: 1, id: pinnedID), legacy("SELECT q", daysAgo: 1)])
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.setPinned(id: pinnedID, pinned: true)
        await store.clear()
        #expect(await store.count() == 0)
    }

    @Test func dedupPreservesPinned() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store.record(sql: "SELECT pin", configName: "c", database: "d")
        let id = try #require(await store.recent(limit: 1).first?.id)
        await store.setPinned(id: id, pinned: true)
        await store.record(sql: "SELECT pin", configName: "c", database: "d")
        #expect(await store.count() == 1)
        #expect(await store.recent(limit: 1).first?.pinned == true)
    }

    // MARK: - 保留期 / 上限

    @Test func retentionPrunesOldNonPinnedButKeepsPinned() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let keepID = UUID()
        try seedLegacy(suite: suite, [legacy("SELECT keep", daysAgo: 40, id: keepID), legacy("SELECT drop", daysAgo: 40)])
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        #expect(await store.count() == 2)
        await store.setPinned(id: keepID, pinned: true)
        await store.setRetentionDays(30)
        let recent = await store.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.sql == "SELECT keep")
    }

    @Test func retentionZeroKeepsOldEntries() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        try seedLegacy(suite: suite, [legacy("SELECT ancient", daysAgo: 400)])
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        #expect(await store.count() == 1)
        #expect(await store.currentRetentionDays() == 0)
    }

    @Test func retentionPersistedAcrossReopen() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store1 = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store1.setRetentionDays(7)
        let store2 = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        #expect(await store2.currentRetentionDays() == 7)
    }

    @Test func capEnforcedForNonPinned() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        try seedLegacy(suite: suite, [
            legacy("s1", daysAgo: 1), legacy("s2", daysAgo: 2), legacy("s3", daysAgo: 3),
            legacy("s4", daysAgo: 4), legacy("s5", daysAgo: 5),
        ])
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!, maxEntries: 3)
        let recent = await store.recent(limit: 10)
        #expect(recent.count == 3)
        #expect(Set(recent.map(\.sql)) == ["s1", "s2", "s3"])
    }

    @Test func pinnedExemptFromCap() async throws {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!, maxEntries: 2)
        await store.record(sql: "SELECT a", configName: "c", database: "d")
        await store.record(sql: "SELECT b", configName: "c", database: "d")
        let aID = try #require(await store.recent(limit: 10).first { $0.sql == "SELECT a" }?.id)
        await store.setPinned(id: aID, pinned: true)
        await store.record(sql: "SELECT c", configName: "c", database: "d")
        let recent = await store.recent(limit: 10)
        // 置顶 a 豁免上限，非置顶保留最新 2 条（b、c）。
        #expect(recent.count == 3)
        #expect(recent.contains { $0.sql == "SELECT a" && $0.pinned })
        #expect(recent.first?.sql == "SELECT a")
    }

    // MARK: - 持久化

    @Test func reopenPersistsRecords() async {
        let suite = makeSuite(), url = makeURL(); defer { cleanup(url: url, suite: suite) }
        let store1 = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        await store1.record(sql: "SELECT durable", configName: "c", database: "d")
        let store2 = QueryHistoryStore(databaseURL: url, defaults: UserDefaults(suiteName: suite)!)
        #expect(await store2.recent(limit: 10).first?.sql == "SELECT durable")
    }
}