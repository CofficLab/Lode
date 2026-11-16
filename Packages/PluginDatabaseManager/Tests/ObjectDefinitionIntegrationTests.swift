import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-3 真实引擎验收：触发器/例程源码编辑（PG/MySQL）。
// 查看→编辑→经写闸门保存（PG 例程 CREATE OR REPLACE；MySQL 例程/触发器与 PG 触发器 DROP+CREATE）→重载核验真实生效。
// readOnly 连接上保存被拒，对象不变。建对象/清理走驱动直连。

private func odPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func odInt(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func odString(_ result: QueryResult) -> String? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .string(let s): return s
    case .data(let d): return String(data: d, encoding: .utf8)
    default: return first.description
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ObjectDefinitionIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    // MARK: - PostgreSQL 例程（CREATE OR REPLACE）

    @Test(.enabled(if: odPort("LODE_TEST_PG_PORT") != nil))
    func pgFunctionEditReplacesBody() async throws {
        let port = try #require(odPort("LODE_TEST_PG_PORT"))
        let schema = "od_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "od", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE FUNCTION \(quoted).od_f() RETURNS integer AS $$ SELECT 1 $$ LANGUAGE sql", params: nil)
        await vm.switchSchema(schema)
        await vm.openObject(DatabaseObject(kind: .function, name: "od_f", schema: schema))
        let ddl = try #require(vm.objectDefinition?.ddl)
        #expect(ddl.contains("CREATE OR REPLACE FUNCTION"))
        #expect(vm.canEditDefinition)

        vm.beginEditDefinition()
        let draft = try #require(vm.objectDefinitionDraft)
        #expect(draft.contains("SELECT 1"))
        vm.objectDefinitionDraft = draft.replacingOccurrences(of: "SELECT 1", with: "SELECT 2")
        await vm.saveDefinition()
        #expect(vm.definitionSaveError == nil)
        #expect(vm.objectDefinitionDraft == nil)
        #expect(odInt(try await conn.query("SELECT \(quoted).od_f()", params: nil)) == 2)
    }

    // MARK: - PostgreSQL 触发器（DROP + CREATE）

    @Test(.enabled(if: odPort("LODE_TEST_PG_PORT") != nil))
    func pgTriggerEditReplacesDefinition() async throws {
        let port = try #require(odPort("LODE_TEST_PG_PORT"))
        let schema = "od_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "od", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).od_t (id integer)", params: nil)
        _ = try await conn.execute("CREATE FUNCTION \(quoted).od_tf() RETURNS trigger AS $$ BEGIN RETURN NEW; END $$ LANGUAGE plpgsql", params: nil)
        _ = try await conn.execute("CREATE TRIGGER od_tr BEFORE INSERT ON \(quoted).od_t FOR EACH ROW EXECUTE FUNCTION \(quoted).od_tf()", params: nil)
        await vm.switchSchema(schema)
        await vm.openObject(DatabaseObject(kind: .trigger, name: "od_tr", schema: schema))
        let ddl = try #require(vm.objectDefinition?.ddl)
        #expect(ddl.contains("BEFORE INSERT"))
        #expect(vm.canEditDefinition)

        vm.beginEditDefinition()
        let draft = try #require(vm.objectDefinitionDraft)
        vm.objectDefinitionDraft = draft.replacingOccurrences(of: "BEFORE INSERT", with: "BEFORE UPDATE")
        await vm.saveDefinition()
        #expect(vm.definitionSaveError == nil)
        let reloaded = try #require(vm.objectDefinition?.ddl)
        #expect(reloaded.contains("BEFORE UPDATE"))
        #expect(!reloaded.contains("BEFORE INSERT"))
    }

    // MARK: - PostgreSQL readOnly 拒绝保存

    @Test(.enabled(if: odPort("LODE_TEST_PG_PORT") != nil))
    func pgReadOnlyBlocksDefinitionSave() async throws {
        let port = try #require(odPort("LODE_TEST_PG_PORT"))
        let schema = "od_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "od", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.readOnly)
        // 建对象/清理/核验走独立连接（vm 连接为 readOnly，直连写也会被驱动层拒绝）。
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { _ = try? await other.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await other.close(); await vm.disconnect() } }
        _ = try await other.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await other.execute("CREATE FUNCTION \(quoted).od_f() RETURNS integer AS $$ SELECT 1 $$ LANGUAGE sql", params: nil)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        await vm.switchSchema(schema)
        await vm.openObject(DatabaseObject(kind: .function, name: "od_f", schema: schema))
        vm.beginEditDefinition()
        let draft = try #require(vm.objectDefinitionDraft)
        vm.objectDefinitionDraft = draft.replacingOccurrences(of: "SELECT 1", with: "SELECT 2")
        await vm.saveDefinition()
        #expect(vm.definitionSaveError != nil)
        #expect(vm.objectDefinitionDraft != nil)  // 编辑态保留
        #expect(odInt(try await other.query("SELECT \(quoted).od_f()", params: nil)) == 1)
    }

    // MARK: - MySQL 例程（DROP + CREATE）

    @Test(.enabled(if: odPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlProcedureEditReplacesBody() async throws {
        let port = try #require(odPort("LODE_TEST_MYSQL_PORT"))
        let database = "od_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "od", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        // switchDatabase 会重连并关闭旧连接，建库/清理/核验走独立直连。
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { _ = try? await other.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil); await other.close(); await vm.disconnect() } }
        _ = try await other.execute("CREATE DATABASE `\(database)`", params: nil)
        // 例程体写会话变量而非返回结果集：CALL 结果集在预处理协议下受限（MySQL 1312）。
        _ = try await other.execute("CREATE PROCEDURE `\(database)`.od_p() BEGIN SET @od_result = 1; END", params: nil)
        await vm.connect(config: config)
        await vm.switchDatabase(database)
        await vm.openObject(DatabaseObject(kind: .procedure, name: "od_p", database: database))
        let ddl = try #require(vm.objectDefinition?.ddl)
        #expect(ddl.contains("CREATE"))
        #expect(ddl.contains("@od_result = 1"))
        #expect(vm.canEditDefinition)

        vm.beginEditDefinition()
        let draft = try #require(vm.objectDefinitionDraft)
        vm.objectDefinitionDraft = draft.replacingOccurrences(of: "@od_result = 1", with: "@od_result = 2")
        await vm.saveDefinition()
        #expect(vm.definitionSaveError == nil)
        _ = try await other.execute("CALL `\(database)`.od_p()", params: nil)
        #expect(odInt(try await other.query("SELECT @od_result", params: nil)) == 2)
    }

    // MARK: - MySQL 触发器（DROP + CREATE，源码现可经 SHOW CREATE TRIGGER 查看）

    @Test(.enabled(if: odPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlTriggerEditReplacesDefinition() async throws {
        let port = try #require(odPort("LODE_TEST_MYSQL_PORT"))
        let database = "od_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "od", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        let seed = try #require(await manager.getConnection(for: config.id))
        _ = try await seed.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await seed.execute("CREATE TABLE `\(database)`.od_t (id INT PRIMARY KEY, x INT) ENGINE=InnoDB", params: nil)
        _ = try await seed.execute("CREATE TRIGGER `\(database)`.od_tr BEFORE INSERT ON `\(database)`.od_t FOR EACH ROW SET NEW.x = 1", params: nil)
        defer { Task {
            if let live = await manager.getConnection(for: config.id) {
                _ = try? await live.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil)
            }
            await vm.disconnect()
        } }
        await vm.switchDatabase(database)
        await vm.openObject(DatabaseObject(kind: .trigger, name: "od_tr", database: database))
        let ddl = try #require(vm.objectDefinition?.ddl)
        #expect(ddl.contains("TRIGGER"))
        #expect(vm.canEditDefinition)

        vm.beginEditDefinition()
        #expect(vm.objectDefinitionDraft != nil)
        // 以完整替换源码保存（DROP 旧触发器 + CREATE 新触发器）。
        vm.objectDefinitionDraft = "CREATE TRIGGER `\(database)`.od_tr BEFORE INSERT ON `\(database)`.od_t FOR EACH ROW SET NEW.x = 2"
        await vm.saveDefinition()
        #expect(vm.definitionSaveError == nil)
        let reloaded = try #require(vm.objectDefinition?.ddl)
        #expect(reloaded.contains("NEW.x = 2"))
    }
}