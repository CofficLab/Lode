import Foundation
import Testing
import ProviderEditor
@testable import DatabaseManagerPlugin

// P3-1 真实引擎补全验收：
// - 真实 SQLite/PG/MySQL 库输入 `SELECT u.` 出现该表列（别名解析 + 元数据加载）；
// - 表名前缀补全；PG schema 限定补全；
// - 建表后失效缓存 → 新表进入候选（缓存刷新）。

private func compPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct SQLCompletionIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func request(_ text: String, offset: Int) -> EditorCompletionRequest {
        EditorCompletionRequest(
            context: EditorFeatureRequestContext(uri: nil, languageID: "sql", revision: 0),
            position: EditorPosition(line: 0, character: offset),
            prefix: "",
            isTypeContext: false,
            documentText: text
        )
    }

    private func labels(_ items: [EditorCompletionItem]) -> [String] { items.map(\.label) }

    @Test func sqliteQualifiedCompletionAndCacheRefresh() async throws {
        let (vm, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-comp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "comp", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE comp_users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)", params: nil)

        let provider = SQLCompletionProvider(
            manager: manager,
            schemaCache: vm.schemaCache,
            configResolver: { vm.selectedConfig },
            debounceNanoseconds: 0
        )

        // 别名限定：SELECT u. → comp_users 的列。
        let qualified = await provider.completions(for: request("SELECT u. FROM comp_users u", offset: 9))
        #expect(Set(labels(qualified)).isSuperset(of: ["id", "name", "email"]))
        #expect(qualified.allSatisfy { $0.kind == .field })

        // 表名前缀。
        let tables = await provider.completions(for: request("SELECT * FROM comp_us", offset: 21))
        #expect(labels(tables).contains("comp_users"))

        // 建表前不含新表。
        let before = await provider.completions(for: request("SELECT * FROM comp_af", offset: 21))
        #expect(!labels(before).contains("comp_after"))

        // 建表 + 失效缓存（与 VM DDL 钩子同一动作）→ 新表进入候选。
        _ = try await other.execute("CREATE TABLE comp_after (id INTEGER PRIMARY KEY, note TEXT)", params: nil)
        #expect(DatabaseViewModel.isSchemaChangeStatement("CREATE TABLE comp_after (id INTEGER)"))
        provider.invalidate(configId: config.id)
        let after = await provider.completions(for: request("SELECT * FROM comp_af", offset: 21))
        #expect(labels(after).contains("comp_after"))
    }

    @Test(.enabled(if: compPort("LODE_TEST_PG_PORT") != nil))
    func postgresQualifiedAndSchemaCompletion() async throws {
        let port = try #require(compPort("LODE_TEST_PG_PORT"))
        // 建表先于 connect：连接时侧栏缓存即包含该表，补全读到非空元数据。
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS comp_pg_users", params: nil)
        _ = try await other.execute("CREATE TABLE comp_pg_users (id INT PRIMARY KEY, name TEXT, email TEXT)", params: nil)

        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "comp", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)

        let provider = SQLCompletionProvider(
            manager: manager,
            schemaCache: vm.schemaCache,
            configResolver: { vm.selectedConfig },
            debounceNanoseconds: 0
        )
        let qualified = await provider.completions(for: request("SELECT u. FROM comp_pg_users u", offset: 9))
        #expect(Set(labels(qualified)).isSuperset(of: ["id", "name", "email"]))

        let schemaTables = await provider.completions(for: request("SELECT * FROM public.", offset: 21))
        #expect(labels(schemaTables).contains("comp_pg_users"))

        _ = try await other.execute("DROP TABLE IF EXISTS comp_pg_users", params: nil)
    }

    @Test(.enabled(if: compPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlQualifiedCompletion() async throws {
        let port = try #require(compPort("LODE_TEST_MYSQL_PORT"))
        // 建表先于 connect：连接时侧栏缓存即包含该表，补全读到非空元数据。
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS comp_my_users", params: nil)
        _ = try await other.execute("CREATE TABLE comp_my_users (id INT PRIMARY KEY, name VARCHAR(64), email VARCHAR(64)) ENGINE=InnoDB", params: nil)

        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "comp", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)

        let provider = SQLCompletionProvider(
            manager: manager,
            schemaCache: vm.schemaCache,
            configResolver: { vm.selectedConfig },
            debounceNanoseconds: 0
        )
        let qualified = await provider.completions(for: request("SELECT u. FROM comp_my_users u", offset: 9))
        #expect(Set(labels(qualified)).isSuperset(of: ["id", "name", "email"]))

        _ = try await other.execute("DROP TABLE IF EXISTS comp_my_users", params: nil)
    }

    @Test func cacheHitCompletionLatency() async throws {
        let (vm, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-comp-lat-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "comp", type: .sqlite, database: path)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE comp_users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)", params: nil)
        await vm.connect(config: config)
        #expect(vm.isConnected)

        let provider = SQLCompletionProvider(
            manager: manager,
            schemaCache: vm.schemaCache,
            configResolver: { vm.selectedConfig },
            debounceNanoseconds: 0
        )
        // 预热：首次加载元数据进缓存。
        _ = await provider.completions(for: request("SELECT u. FROM comp_users u", offset: 9))

        // 缓存命中延迟实测：P3 阶段门要求 <100ms。
        var maxMs = 0.0
        for _ in 0..<10 {
            let start = Date()
            let items = await provider.completions(for: request("SELECT u. FROM comp_users u", offset: 9))
            let ms = Date().timeIntervalSince(start) * 1000
            maxMs = max(maxMs, ms)
            #expect(!items.isEmpty)
        }
        #expect(maxMs < 100, "cache-hit completion took \(maxMs)ms")
    }

    @Test func utf16OffsetMultiline() {
        #expect(SQLCompletionProvider.utf16Offset(of: EditorPosition(line: 0, character: 2), in: "ab\ncdef") == 2)
        #expect(SQLCompletionProvider.utf16Offset(of: EditorPosition(line: 1, character: 2), in: "ab\ncdef") == 5)
        #expect(SQLCompletionProvider.utf16Offset(of: EditorPosition(line: 9, character: 0), in: "ab") == 2)
    }

    @Test func schemaChangeClassification() {
        #expect(DatabaseViewModel.isSchemaChangeStatement("CREATE TABLE t (id INT)"))
        #expect(DatabaseViewModel.isSchemaChangeStatement("  alter table t add column x int"))
        #expect(DatabaseViewModel.isSchemaChangeStatement("DROP TABLE t"))
        #expect(!DatabaseViewModel.isSchemaChangeStatement("SELECT * FROM t"))
        #expect(!DatabaseViewModel.isSchemaChangeStatement("INSERT INTO t VALUES (1)"))
    }
}