import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P4-5 真实引擎验收：对象树库/schema 切换器。
// - PG 切 schema 后对象树与查询上下文（search_path）一致；
// - MySQL 切库经重连，对象树与 SELECT DATABASE() 跟随；
// - 连接后默认上下文（活动库=配置库，PG 活动 schema=public，可切换列表非空）。
//
// 需本地 Docker：设置 LODE_TEST_PG_PORT / LODE_TEST_MYSQL_PORT 后启用。
// 每个用例建独立随机命名的 schema/库，结束 DROP 清理。

private func scPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func scText(_ result: QueryResult, _ row: Int = 0, _ col: Int = 0) -> String {
    guard row < result.rows.count, col < result.rows[row].count else { return "" }
    let value = result.rows[row][col]
    if case .string(let s) = value { return s }
    return value.description
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct SchemaContextIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func tableObjects(_ vm: DatabaseViewModel, config: DatabaseConfig, database: String?, schema: String?) -> [DatabaseObject] {
        let key = SchemaCacheService.CacheKey(configId: config.id, kind: .table, database: database, schema: schema)
        return vm.schemaCache.objectsByKey[key] ?? []
    }

    // MARK: - PostgreSQL：schema 切换

    @Test(.enabled(if: scPort("LODE_TEST_PG_PORT") != nil))
    func pgSchemaSwitchFollowsTreeAndContext() async throws {
        let port = try #require(scPort("LODE_TEST_PG_PORT"))
        let schema = "p45_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "sc", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).t45 (id integer)", params: nil)

        // 默认上下文：活动库=配置库，活动 schema=public，可切换列表含新建 schema。
        #expect(vm.activeDatabase == "testdb")
        #expect(vm.activeSchema == "public")
        #expect(vm.availableDatabases.contains("testdb"))
        await vm.switchSchema(schema)
        #expect(vm.activeSchema == schema)

        // 查询上下文跟随：search_path 含新 schema，未限定查询可解析到该 schema 的表。
        let searchPath = try await conn.query("SHOW search_path", params: nil)
        #expect(scText(searchPath).contains(schema))
        let unqualified = try await conn.query("SELECT * FROM t45", params: nil)
        #expect(unqualified.columns == ["id"])

        // 对象树跟随：新 schema 键含 t45，public 键不含。
        let inSchema = tableObjects(vm, config: config, database: "testdb", schema: schema)
        #expect(inSchema.contains { $0.name == "t45" })
        let inPublic = tableObjects(vm, config: config, database: "testdb", schema: "public")
        #expect(!inPublic.contains { $0.name == "t45" })
    }

    @Test(.enabled(if: scPort("LODE_TEST_PG_PORT") != nil))
    func pgSchemaListIncludesCreatedSchema() async throws {
        let port = try #require(scPort("LODE_TEST_PG_PORT"))
        let schema = "p45_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "sc", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        // 切换会刷新对象树并连带刷新 schema 列表，新建 schema 应进入可切换列表。
        await vm.switchSchema(schema)
        #expect(vm.activeSchema == schema)
        #expect(vm.availableSchemas.contains(schema))
    }

    // MARK: - MySQL：库切换（重连）

    @Test(.enabled(if: scPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlDatabaseSwitchReconnects() async throws {
        let port = try #require(scPort("LODE_TEST_MYSQL_PORT"))
        let database = "p45_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "sc", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let seed = try #require(await manager.getConnection(for: config.id))
        _ = try await seed.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await seed.execute("CREATE TABLE `\(database)`.t45 (id INT)", params: nil)
        // 切库会重连，seed 可能已失效；清理时用当前活动连接 DROP，再断开。
        defer { Task {
            if let live = await manager.getConnection(for: config.id) {
                _ = try? await live.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil)
            }
            await vm.disconnect()
        } }

        #expect(vm.activeDatabase == "testdb")
        await vm.switchDatabase(database)
        #expect(vm.isConnected)
        #expect(vm.activeDatabase == database)
        #expect(vm.selectedConfig?.database == database)

        // 重连后的新连接已绑定新库。
        let conn = try #require(await manager.getConnection(for: config.id))
        let current = try await conn.query("SELECT DATABASE()", params: nil)
        #expect(scText(current) == database)

        // 对象树跟随新库。
        let objects = tableObjects(vm, config: config, database: database, schema: nil)
        #expect(objects.contains { $0.name == "t45" })
    }
}