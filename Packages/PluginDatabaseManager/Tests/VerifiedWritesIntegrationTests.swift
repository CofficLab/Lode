import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P1-6 真实引擎验收：
// - 两个客户端改同一行，后提交者收到冲突提示而非静默覆盖（乐观锁）；
// - 冲突解决「覆盖」强制写入、「放弃」保留他人值；
// - 无主键表编辑往返（MySQL/PG 全列匹配，SQLite rowid）；
// - 行被他人删除 → missing 冲突，覆盖也无法复活（写验证中止）；
// - 无主键重复行 → ambiguous（MySQL/PG），SQLite 用 rowid 精确区分。
//
// 网络引擎需本地 Docker：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT 后启用。
// SQLite 用临时文件库，无需 Docker，始终运行。
// `other` 为独立的第二连接，模拟「另一个客户端」的已提交改动。

private func vwPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func vwInt(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func vwString(_ result: QueryResult) -> String? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .string(let s): return s
    // MySQL 把 TEXT 列按 blob 线上类型返回 .data；按 UTF-8 还原文本。
    case .data(let d): return String(data: d, encoding: .utf8)
    default: return first.description
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct VerifiedWritesIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    /// 通用场景：主键冲突检测/覆盖/放弃、无主键往返、行缺失中止。
    private func runCommonScenarios(
        vm: DatabaseViewModel,
        other: any DatabaseConnection,
        objectPK: DatabaseObject,
        objectNoPK: DatabaseObject
    ) async throws {
        // A. 后提交者检测到冲突，数据库不被静默覆盖；覆盖后强制写入。
        _ = try await other.execute("DROP TABLE IF EXISTS vw_pk", params: nil)
        _ = try await other.execute("CREATE TABLE vw_pk (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO vw_pk (id, name) VALUES (1, 'ann')", params: nil)
        await vm.openObject(objectPK)
        let pkRow = try #require(vm.queryResult?.rows.first)
        let pkCols = try #require(vm.queryResult?.columns)
        vm.stageCellChange(column: "name", newValue: .string("anne"), rowValues: pkRow, columns: pkCols)
        #expect(vm.changeManager?.hasChanges == true)
        _ = try await other.execute("UPDATE vw_pk SET name = 'bob' WHERE id = 1", params: nil)
        await vm.saveChanges()
        #expect(vm.pendingConflicts.count == 1)
        #expect(vm.pendingConflicts.first?.kind == .changed)
        #expect(vm.pendingConflicts.first?.changedColumns == ["name"])
        #expect(vm.showConflictSheet)
        #expect(vm.changeManager?.hasChanges == true)
        #expect(vwString(try await other.query("SELECT name FROM vw_pk WHERE id = 1", params: nil)) == "bob")
        await vm.overwriteConflictsAndSave()
        #expect(vwString(try await other.query("SELECT name FROM vw_pk WHERE id = 1", params: nil)) == "anne")
        #expect(vm.changeManager?.hasChanges == false)

        // B. 放弃冲突行：保留他人值，队列清空。
        _ = try await other.execute("UPDATE vw_pk SET name = 'ann' WHERE id = 1", params: nil)
        await vm.openObject(objectPK)
        let pkRow2 = try #require(vm.queryResult?.rows.first)
        vm.stageCellChange(column: "name", newValue: .string("anne"), rowValues: pkRow2, columns: pkCols)
        _ = try await other.execute("UPDATE vw_pk SET name = 'carol' WHERE id = 1", params: nil)
        await vm.saveChanges()
        #expect(vm.pendingConflicts.first?.kind == .changed)
        await vm.discardConflictedRowsAndSave()
        #expect(vwString(try await other.query("SELECT name FROM vw_pk WHERE id = 1", params: nil)) == "carol")
        #expect(vm.changeManager?.hasChanges == false)

        // C. 无主键表编辑往返成功。
        _ = try await other.execute("DROP TABLE IF EXISTS vw_nopk", params: nil)
        _ = try await other.execute("CREATE TABLE vw_nopk (a INTEGER, b TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO vw_nopk (a, b) VALUES (1, 'x')", params: nil)
        await vm.openObject(objectNoPK)
        #expect(vm.changeManager?.isEditable == true)
        let npRow = try #require(vm.queryResult?.rows.first)
        let npCols = try #require(vm.queryResult?.columns)
        vm.stageCellChange(column: "b", newValue: .string("y"), rowValues: npRow, columns: npCols)
        await vm.saveChanges()
        #expect(vm.pendingConflicts.isEmpty)
        #expect(vwString(try await other.query("SELECT b FROM vw_nopk WHERE a = 1", params: nil)) == "y")

        // D. 行被他人删除 → missing 冲突；覆盖也无法复活，写验证中止。
        _ = try await other.execute("UPDATE vw_pk SET name = 'ann' WHERE id = 1", params: nil)
        await vm.openObject(objectPK)
        let pkRow3 = try #require(vm.queryResult?.rows.first)
        vm.stageCellChange(column: "name", newValue: .string("anne"), rowValues: pkRow3, columns: pkCols)
        _ = try await other.execute("DELETE FROM vw_pk WHERE id = 1", params: nil)
        await vm.saveChanges()
        #expect(vm.pendingConflicts.first?.kind == .missing)
        #expect(vm.showConflictSheet)
        await vm.overwriteConflictsAndSave()
        #expect(vm.errorMessage != nil)
        #expect(vwInt(try await other.query("SELECT COUNT(*) FROM vw_pk", params: nil)) == 0)

        _ = try await other.execute("DROP TABLE IF EXISTS vw_pk", params: nil)
        _ = try await other.execute("DROP TABLE IF EXISTS vw_nopk", params: nil)
    }

    /// 无主键重复行 → 全列匹配命中多行 → ambiguous（MySQL/PG）。
    private func runAmbiguousScenario(vm: DatabaseViewModel, other: any DatabaseConnection, object: DatabaseObject) async throws {
        _ = try await other.execute("DROP TABLE IF EXISTS vw_amb", params: nil)
        _ = try await other.execute("CREATE TABLE vw_amb (v TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO vw_amb (v) VALUES ('dup')", params: nil)
        _ = try await other.execute("INSERT INTO vw_amb (v) VALUES ('dup')", params: nil)
        await vm.openObject(object)
        let result = try #require(vm.queryResult)
        #expect(result.rows.count == 2)
        vm.stageCellChange(column: "v", newValue: .string("changed"), rowValues: result.rows[0], columns: result.columns)
        await vm.saveChanges()
        #expect(vm.pendingConflicts.first?.kind == .ambiguous)
        #expect(vm.showConflictSheet)
        #expect(vwInt(try await other.query("SELECT COUNT(*) FROM vw_amb WHERE v = 'changed'", params: nil)) == 0)
        _ = try await other.execute("DROP TABLE IF EXISTS vw_amb", params: nil)
    }

    // MARK: - MySQL

    @Test(.enabled(if: vwPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlVerifiedWrites() async throws {
        let port = try #require(vwPort("LODE_TEST_MYSQL_PORT"))
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "vw", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        try await runCommonScenarios(vm: vm, other: other, objectPK: DatabaseObject(kind: .table, name: "vw_pk", database: "testdb"), objectNoPK: DatabaseObject(kind: .table, name: "vw_nopk", database: "testdb"))
        try await runAmbiguousScenario(vm: vm, other: other, object: DatabaseObject(kind: .table, name: "vw_amb", database: "testdb"))
        await vm.disconnect()
    }

    // MARK: - PostgreSQL

    @Test(.enabled(if: vwPort("LODE_TEST_PG_PORT") != nil))
    func pgVerifiedWrites() async throws {
        let port = try #require(vwPort("LODE_TEST_PG_PORT"))
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "vw", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        try await runCommonScenarios(vm: vm, other: other, objectPK: DatabaseObject(kind: .table, name: "vw_pk", schema: "public"), objectNoPK: DatabaseObject(kind: .table, name: "vw_nopk", schema: "public"))
        try await runAmbiguousScenario(vm: vm, other: other, object: DatabaseObject(kind: .table, name: "vw_amb", schema: "public"))
        await vm.disconnect()
    }

    // MARK: - SQLite

    @Test func sqliteVerifiedWrites() async throws {
        let (vm, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-vw-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "vw", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        try await runCommonScenarios(vm: vm, other: other, objectPK: DatabaseObject(kind: .table, name: "vw_pk"), objectNoPK: DatabaseObject(kind: .table, name: "vw_nopk"))
        await vm.disconnect()
    }

    @Test func sqliteRowidDisambiguatesDuplicateRows() async throws {
        let (vm, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-vw-dup-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "vw", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        _ = try await conn.execute("CREATE TABLE vw_dup (v TEXT)", params: nil)
        _ = try await conn.execute("INSERT INTO vw_dup (v) VALUES ('same')", params: nil)
        _ = try await conn.execute("INSERT INTO vw_dup (v) VALUES ('same')", params: nil)
        await vm.openObject(DatabaseObject(kind: .table, name: "vw_dup"))
        let result = try #require(vm.queryResult)
        #expect(result.columns.contains("rowid"))
        #expect(result.rows.count == 2)
        // 仅编辑第一行：rowid 定位可区分完全相同的重复行。
        vm.stageCellChange(column: "v", newValue: .string("changed"), rowValues: result.rows[0], columns: result.columns)
        await vm.saveChanges()
        #expect(vm.pendingConflicts.isEmpty)
        #expect(vwInt(try await conn.query("SELECT COUNT(*) FROM vw_dup WHERE v = 'changed'", params: nil)) == 1)
        #expect(vwInt(try await conn.query("SELECT COUNT(*) FROM vw_dup WHERE v = 'same'", params: nil)) == 1)
        await vm.disconnect()
    }
}