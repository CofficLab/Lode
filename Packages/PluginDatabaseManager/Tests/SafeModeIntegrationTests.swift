import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P1-7 真实引擎验收：
// - readOnly 连接上执行 UPDATE 被拒（编辑器 / 变更队列 / DDL / 驱动层硬保证），读仍可用；
// - confirmWrites 连接上提交变更需确认（确认→执行、取消→中止），覆盖编辑器/批量/表编辑/DDL；
// - off 档写操作照常执行（不回归）。
//
// 网络引擎需本地 Docker：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT / LODE_TEST_REDIS_PORT 后启用。
// SQLite 用临时文件库，无需 Docker，始终运行。`other` 为独立第二连接，用于建表与核验真实落库结果。

private func smPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func smInt(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func smString(_ result: QueryResult) -> String? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .string(let s): return s
    case .data(let d): return String(data: d, encoding: .utf8)
    default: return first.description
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct SafeModeIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    /// 让出主 actor 直到写确认弹窗出现（写流程挂起在续体上）。超时返回 false。
    private func waitForConfirmation(_ vm: DatabaseViewModel) async -> Bool {
        for _ in 0..<5000 {
            if vm.writeConfirmation != nil { return true }
            await Task.yield()
        }
        return false
    }

    private func makeSQLiteConfig(_ mode: ConnectionSafeMode, path: String) -> DatabaseConfig {
        DatabaseConfig(name: "sm", type: .sqlite, database: path).withSafeMode(mode)
    }

    // MARK: - SQLite：off 档不回归

    @Test func sqliteOffModeWritesExecute() async throws {
        let (vm, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-off-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO sm_t (id, name) VALUES (1, 'ann')", params: nil)
        await vm.connect(config: makeSQLiteConfig(.off, path: path))
        #expect(vm.isConnected)
        vm.queryText = "UPDATE sm_t SET name = 'anne' WHERE id = 1"
        await vm.executeQuery()
        #expect(vm.errorMessage == nil)
        #expect(smString(try await other.query("SELECT name FROM sm_t WHERE id = 1", params: nil)) == "anne")
        await vm.disconnect()
        _ = manager
    }

    // MARK: - SQLite：readOnly 拒绝写

    @Test func sqliteReadOnlyBlocksEditorUpdate() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-ro-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO sm_t (id, name) VALUES (1, 'ann')", params: nil)
        await vm.connect(config: makeSQLiteConfig(.readOnly, path: path))
        #expect(vm.isConnected)

        // 读仍可用。
        vm.queryText = "SELECT name FROM sm_t WHERE id = 1"
        await vm.executeQuery()
        #expect(vm.errorMessage == nil)
        #expect(smString(try #require(vm.queryResult)) == "ann")

        // 写被拒，数据库不变，错误归类为权限不足（恢复动作：编辑连接）。
        vm.queryText = "UPDATE sm_t SET name = 'hacked' WHERE id = 1"
        await vm.executeQuery()
        #expect(vm.errorMessage != nil)
        #expect(vm.classifiedError?.category == .permissionDenied)
        #expect(smString(try await other.query("SELECT name FROM sm_t WHERE id = 1", params: nil)) == "ann")
        await vm.disconnect()
    }

    @Test func sqliteReadOnlyDriverBackstop() async throws {
        let (vm, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-backstop-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO sm_t (id, name) VALUES (1, 'ann')", params: nil)
        let config = makeSQLiteConfig(.readOnly, path: path)
        await vm.connect(config: config)
        let conn = try #require(await manager.getConnection(for: config.id))

        // 读放行。
        _ = try await conn.query("SELECT * FROM sm_t", params: nil)

        // execute 写被驱动层拒绝。
        do {
            _ = try await conn.execute("UPDATE sm_t SET name = 'x' WHERE id = 1", params: nil)
            Issue.record("readOnly execute should have thrown")
        } catch {
            #expect(error.localizedDescription.contains("read-only"))
        }
        // query 路径的写（INSERT ... RETURNING）同样被拒。
        do {
            _ = try await conn.query("INSERT INTO sm_t (name) VALUES ('z') RETURNING id", params: nil)
            Issue.record("readOnly query-write should have thrown")
        } catch {
            #expect(error.localizedDescription.contains("read-only"))
        }
        // 事务内写被拒，commit/rollback 仍可用。
        let tx = try await conn.beginTransaction()
        do {
            _ = try await tx.execute("DELETE FROM sm_t WHERE id = 1", params: nil)
            Issue.record("readOnly tx.execute should have thrown")
        } catch {
            #expect(error.localizedDescription.contains("read-only"))
        }
        try await tx.rollback()
        #expect(smInt(try await other.query("SELECT COUNT(*) FROM sm_t", params: nil)) == 1)
        await vm.disconnect()
    }

    @Test func sqliteReadOnlyBlocksTableEdit() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-ro-edit-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO sm_t (id, name) VALUES (1, 'ann')", params: nil)
        await vm.connect(config: makeSQLiteConfig(.readOnly, path: path))
        await vm.openObject(DatabaseObject(kind: .table, name: "sm_t"))
        let row = try #require(vm.queryResult?.rows.first)
        let cols = try #require(vm.queryResult?.columns)
        vm.stageCellChange(column: "name", newValue: .string("hacked"), rowValues: row, columns: cols)
        #expect(vm.changeManager?.hasChanges == true)
        await vm.saveChanges()
        #expect(vm.errorMessage != nil)
        #expect(vm.changeManager?.hasChanges == true)  // 队列保留
        #expect(smString(try await other.query("SELECT name FROM sm_t WHERE id = 1", params: nil)) == "ann")
        await vm.disconnect()
    }

    @Test func sqliteReadOnlyBlocksSchemaChange() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-ro-ddl-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        await vm.connect(config: makeSQLiteConfig(.readOnly, path: path))
        await vm.openObject(DatabaseObject(kind: .table, name: "sm_t"))
        let manager = try #require(vm.schemaChangeManager)
        try manager.stageAdd(NewTableColumnDraft(name: "extra", dataType: "TEXT"))
        #expect(manager.hasChanges)
        await vm.saveSchemaChanges()
        #expect(vm.tableSchemaError != nil)
        let cols = try await other.query("PRAGMA table_info(sm_t)", params: nil)
        #expect(cols.rows.contains { $0.contains(.string("extra")) } == false)
        await vm.disconnect()
    }

    // MARK: - SQLite：confirmWrites 需确认

    @Test func sqliteConfirmEditorUpdateApproveAndCancel() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-cf-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO sm_t (id, name) VALUES (1, 'ann')", params: nil)
        await vm.connect(config: makeSQLiteConfig(.confirmWrites, path: path))

        // 取消：写流程中止，数据库不变。
        vm.queryText = "UPDATE sm_t SET name = 'cancelled' WHERE id = 1"
        let cancelTask = Task { await vm.executeQuery() }
        #expect(await waitForConfirmation(vm))
        #expect(vm.writeConfirmation?.kind == .query)
        #expect(smString(try await other.query("SELECT name FROM sm_t WHERE id = 1", params: nil)) == "ann")
        vm.resolveWriteConfirmation(false)
        await cancelTask.value
        #expect(vm.writeConfirmation == nil)
        #expect(smString(try await other.query("SELECT name FROM sm_t WHERE id = 1", params: nil)) == "ann")

        // 确认：写流程继续，数据库更新。
        vm.queryText = "UPDATE sm_t SET name = 'approved' WHERE id = 1"
        let approveTask = Task { await vm.executeQuery() }
        #expect(await waitForConfirmation(vm))
        vm.resolveWriteConfirmation(true)
        await approveTask.value
        #expect(smString(try await other.query("SELECT name FROM sm_t WHERE id = 1", params: nil)) == "approved")
        await vm.disconnect()
    }

    @Test func sqliteConfirmTableEditRequiresConfirmation() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-cf-edit-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO sm_t (id, name) VALUES (1, 'ann')", params: nil)
        await vm.connect(config: makeSQLiteConfig(.confirmWrites, path: path))
        await vm.openObject(DatabaseObject(kind: .table, name: "sm_t"))
        let row = try #require(vm.queryResult?.rows.first)
        let cols = try #require(vm.queryResult?.columns)
        vm.stageCellChange(column: "name", newValue: .string("anne"), rowValues: row, columns: cols)

        let task = Task { await vm.saveChanges() }
        #expect(await waitForConfirmation(vm))
        #expect(vm.writeConfirmation?.kind == .tableEdit)
        // 确认前数据库未变。
        #expect(smString(try await other.query("SELECT name FROM sm_t WHERE id = 1", params: nil)) == "ann")
        vm.resolveWriteConfirmation(true)
        await task.value
        #expect(vm.changeManager?.hasChanges == false)
        #expect(smString(try await other.query("SELECT name FROM sm_t WHERE id = 1", params: nil)) == "anne")
        await vm.disconnect()
    }

    @Test func sqliteConfirmSchemaChangeRequiresConfirmation() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-cf-ddl-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        await vm.connect(config: makeSQLiteConfig(.confirmWrites, path: path))
        await vm.openObject(DatabaseObject(kind: .table, name: "sm_t"))
        let manager = try #require(vm.schemaChangeManager)
        try manager.stageAdd(NewTableColumnDraft(name: "extra", dataType: "TEXT"))

        let task = Task { await vm.saveSchemaChanges() }
        #expect(await waitForConfirmation(vm))
        #expect(vm.writeConfirmation?.kind == .schemaChange)
        vm.resolveWriteConfirmation(true)
        await task.value
        #expect(vm.tableSchemaError == nil)
        let cols = try await other.query("PRAGMA table_info(sm_t)", params: nil)
        #expect(cols.rows.contains { $0.contains(.string("extra")) })
        await vm.disconnect()
    }

    @Test func sqliteConfirmBatchRequiresSingleConfirmation() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-cf-batch-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        await vm.connect(config: makeSQLiteConfig(.confirmWrites, path: path))
        vm.queryText = "INSERT INTO sm_t (id, name) VALUES (1, 'a'); INSERT INTO sm_t (id, name) VALUES (2, 'b')"
        let task = Task { await vm.executeAllStatements() }
        #expect(await waitForConfirmation(vm))
        #expect(vm.writeConfirmation?.kind == .batch)
        #expect(vm.writeConfirmation?.writeCount == 2)
        vm.resolveWriteConfirmation(true)
        await task.value
        #expect(smInt(try await other.query("SELECT COUNT(*) FROM sm_t", params: nil)) == 2)
        await vm.disconnect()
    }

    @Test func sqliteReadOnlyBlocksBatch() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-sm-ro-batch-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE sm_t (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        await vm.connect(config: makeSQLiteConfig(.readOnly, path: path))
        vm.queryText = "SELECT 1; INSERT INTO sm_t (id, name) VALUES (1, 'a')"
        await vm.executeAllStatements()
        #expect(vm.errorMessage != nil)
        #expect(smInt(try await other.query("SELECT COUNT(*) FROM sm_t", params: nil)) == 0)
        await vm.disconnect()
    }

    // MARK: - MySQL / PostgreSQL：readOnly 验收

    @Test(.enabled(if: smPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlReadOnlyRejectsUpdate() async throws {
        let port = try #require(smPort("LODE_TEST_MYSQL_PORT"))
        let (vm, manager) = await makeSUT()
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS sm_ro", params: nil)
        _ = try await other.execute("CREATE TABLE sm_ro (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO sm_ro (id, name) VALUES (1, 'ann')", params: nil)
        let config = DatabaseConfig(name: "sm", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.readOnly)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        vm.queryText = "UPDATE sm_ro SET name = 'hacked' WHERE id = 1"
        await vm.executeQuery()
        #expect(vm.errorMessage != nil)
        #expect(smString(try await other.query("SELECT name FROM sm_ro WHERE id = 1", params: nil)) == "ann")
        // 驱动层硬保证：绕过 VM 直接写也被拒。
        let conn = try #require(await manager.getConnection(for: config.id))
        do {
            _ = try await conn.execute("DELETE FROM sm_ro WHERE id = 1", params: nil)
            Issue.record("readOnly MySQL execute should have thrown")
        } catch {
            #expect(error.localizedDescription.contains("read-only"))
        }
        #expect(smInt(try await other.query("SELECT COUNT(*) FROM sm_ro", params: nil)) == 1)
        _ = try await other.execute("DROP TABLE IF EXISTS sm_ro", params: nil)
        await vm.disconnect()
    }

    @Test(.enabled(if: smPort("LODE_TEST_PG_PORT") != nil))
    func pgReadOnlyRejectsUpdate() async throws {
        let port = try #require(smPort("LODE_TEST_PG_PORT"))
        let (vm, manager) = await makeSUT()
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS sm_ro", params: nil)
        _ = try await other.execute("CREATE TABLE sm_ro (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO sm_ro (id, name) VALUES (1, 'ann')", params: nil)
        let config = DatabaseConfig(name: "sm", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.readOnly)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        vm.queryText = "UPDATE sm_ro SET name = 'hacked' WHERE id = 1"
        await vm.executeQuery()
        #expect(vm.errorMessage != nil)
        #expect(smString(try await other.query("SELECT name FROM sm_ro WHERE id = 1", params: nil)) == "ann")
        let conn = try #require(await manager.getConnection(for: config.id))
        do {
            _ = try await conn.execute("DELETE FROM sm_ro WHERE id = 1", params: nil)
            Issue.record("readOnly PG execute should have thrown")
        } catch {
            #expect(error.localizedDescription.contains("read-only"))
        }
        #expect(smInt(try await other.query("SELECT COUNT(*) FROM sm_ro", params: nil)) == 1)
        _ = try await other.execute("DROP TABLE IF EXISTS sm_ro", params: nil)
        await vm.disconnect()
    }

    // MARK: - Redis：readOnly 验收

    @Test(.enabled(if: smPort("LODE_TEST_REDIS_PORT") != nil))
    func redisReadOnlyRejectsWrite() async throws {
        let port = try #require(smPort("LODE_TEST_REDIS_PORT"))
        let (vm, manager) = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await other.close() } }
        _ = try await other.execute("SET sm_ro_key original", params: nil)
        let config = DatabaseConfig(name: "sm", type: .redis, host: "127.0.0.1", port: port, database: "0").withSafeMode(.readOnly)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        // 写命令被拒。
        do {
            _ = try await conn.execute("SET sm_ro_key hacked", params: nil)
            Issue.record("readOnly Redis SET should have thrown")
        } catch {
            #expect(error.localizedDescription.contains("read-only"))
        }
        // 读命令放行，值未被改动（GET 结果第二列为 Value）。
        let result = try await conn.query("GET sm_ro_key", params: nil)
        let value = result.rows.first?[1]
        #expect(value == .string("original"))
        _ = try await other.execute("DEL sm_ro_key", params: nil)
        await vm.disconnect()
    }
}