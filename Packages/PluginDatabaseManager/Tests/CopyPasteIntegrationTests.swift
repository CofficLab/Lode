import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-4 真实引擎验收（复制 → 执行 / 粘贴 → 保存）：
// - 复制 INSERT 语句可在独立连接直接执行，完整还原原行（含 NULL、引号/逗号文本）；
// - 复制 UPDATE 使用显示值（含未保存的暂存编辑），按主键定位执行后数据库生效；
// - 粘贴 CSV（位置/表头乱序）与 JSON（缺键保留 DEFAULT、null 显式置空）→ 变更队列 →
//   保存 → 数据库落行正确；
// - 无主键表拒绝生成 UPDATE；非法剪贴板内容报错且不产生变更。
//
// 网络引擎需本地 Docker：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT 后启用。
// SQLite 用临时文件库，始终运行。`other` 为独立第二连接，用于执行复制出的 SQL 与核验。

private func cpPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func cpText(_ value: DatabaseValue) -> String? {
    switch value {
    case .string(let s): return s
    case .data(let d): return String(data: d, encoding: .utf8)
    default: return nil
    }
}

private func cpInt(_ value: DatabaseValue) -> Int? {
    switch value {
    case .integer(let i): return i
    case .bool(let b): return b ? 1 : 0
    case .string(let s): return Int(s)
    case .data(let d): return String(data: d, encoding: .utf8).flatMap(Int.init)
    default: return nil
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct CopyPasteIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    // MARK: - SQLite

    @Test func sqliteCopyExecuteAndPasteSave() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-cp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "cp", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }

        _ = try await other.execute(
            "CREATE TABLE cp_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'def', qty INTEGER DEFAULT 7, note TEXT)",
            params: nil)
        _ = try await other.execute("INSERT INTO cp_items (id, name, qty, note) VALUES (1, 'first', 3, 'n1')", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "cp_items"))
        #expect(vm.queryResult?.rows.count == 1)
        #expect(vm.gridHasRowKey)

        // IN 列表与页级复制
        #expect(vm.gridInListText(column: "id") == "(1)")
        #expect(vm.gridPageText(.csv) == "id,name,qty,note\r\n1,first,3,n1")
        #expect(vm.gridPageText(.markdown)?.hasPrefix("| id | name | qty | note |") == true)

        // 复制 INSERT → 删除原行 → 直接执行 → 完整还原（含特殊字符与 NULL）
        _ = try await other.execute(
            "INSERT INTO cp_items (id, name, qty, note) VALUES (2, 'O''Brien, \"q\"', 42, NULL)", params: nil)
        await vm.openObject(DatabaseObject(kind: .table, name: "cp_items"))
        let result = try #require(vm.queryResult)
        let specialRow = try #require(result.rows.first { cpInt($0[0]) == 2 })
        let insertSQL = try #require(vm.gridCopyText(rowKind: .insert, row: specialRow, columns: result.columns))
        _ = try await other.execute("DELETE FROM cp_items WHERE id = 2", params: nil)
        _ = try await other.execute(insertSQL, params: nil)
        let restored = try await other.query("SELECT name, qty, note FROM cp_items WHERE id = 2", params: nil)
        let restoredRow = try #require(restored.rows.first)
        #expect(cpText(restoredRow[0]) == "O'Brien, \"q\"")
        #expect(cpInt(restoredRow[1]) == 42)
        #expect(restoredRow[2] == .null)

        // 复制 UPDATE 使用暂存显示值：staged qty = 99 → 执行后数据库生效
        let firstRow = try #require(result.rows.first { cpInt($0[0]) == 1 })
        vm.stageCellChange(column: "qty", newValue: .integer(99), rowValues: firstRow, columns: result.columns)
        let updateSQL = try #require(vm.gridCopyText(rowKind: .update, row: firstRow, columns: result.columns))
        #expect(updateSQL.contains("\"qty\" = 99"))
        #expect(updateSQL.contains("WHERE \"id\" = 1"))
        _ = try await other.execute(updateSQL, params: nil)
        let updated = try await other.query("SELECT qty FROM cp_items WHERE id = 1", params: nil)
        #expect(cpInt(try #require(updated.rows.first?.first)) == 99)
        vm.discardChanges()
        #expect(vm.changeManager?.hasChanges == false)

        // 粘贴位置 CSV → 保存 → 落行
        #expect(vm.gridPasteRows(from: "3,third,5\n4,fourth,6") == 2)
        #expect(vm.changeManager?.pendingInsertCount == 2)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        let pasted = try await other.query("SELECT name, qty FROM cp_items WHERE id IN (3, 4) ORDER BY id", params: nil)
        #expect(pasted.rows.count == 2)
        #expect(cpText(pasted.rows[0][0]) == "third")
        #expect(cpInt(pasted.rows[0][1]) == 5)
        #expect(cpText(pasted.rows[1][0]) == "fourth")

        // 粘贴 JSON：缺键保留 DEFAULT，null 显式置空
        #expect(vm.gridPasteRows(from: "[{\"id\":5},{\"id\":6,\"name\":\"sixth\",\"qty\":null}]") == 2)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        let defaults = try await other.query("SELECT name, qty, note FROM cp_items WHERE id = 5", params: nil)
        let defaultRow = try #require(defaults.rows.first)
        #expect(cpText(defaultRow[0]) == "def")
        #expect(cpInt(defaultRow[1]) == 7)
        #expect(defaultRow[2] == .null)
        let explicit = try await other.query("SELECT name, qty FROM cp_items WHERE id = 6", params: nil)
        let explicitRow = try #require(explicit.rows.first)
        #expect(cpText(explicitRow[0]) == "sixth")
        #expect(explicitRow[1] == .null)

        // 粘贴表头乱序 CSV → 按名映射
        #expect(vm.gridPasteRows(from: "qty,name,id\n8,eight,7") == 1)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        let reordered = try await other.query("SELECT name, qty FROM cp_items WHERE id = 7", params: nil)
        let reorderedRow = try #require(reordered.rows.first)
        #expect(cpText(reorderedRow[0]) == "eight")
        #expect(cpInt(reorderedRow[1]) == 8)

        // 无主键 SQLite 表：rowid 别名兜底行键，UPDATE 按 rowid 定位且可执行
        _ = try await other.execute("CREATE TABLE cp_nopk (a TEXT, b TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO cp_nopk (a, b) VALUES ('x', 'y')", params: nil)
        await vm.openObject(DatabaseObject(kind: .table, name: "cp_nopk"))
        #expect(vm.gridHasRowKey)
        let nopkResult = try #require(vm.queryResult)
        #expect(nopkResult.columns.contains("rowid"))
        let nopkUpdate = try #require(vm.gridCopyText(rowKind: .update, row: nopkResult.rows[0], columns: nopkResult.columns))
        #expect(nopkUpdate.contains("WHERE \"rowid\" = "))
        _ = try await other.execute(nopkUpdate.replacingOccurrences(of: "'x'", with: "'changed'"), params: nil)
        let nopkSaved = try await other.query("SELECT a FROM cp_nopk", params: nil)
        #expect(cpText(try #require(nopkSaved.rows.first?.first)) == "changed")

        // 非法剪贴板内容：报错且不产生变更
        await vm.openObject(DatabaseObject(kind: .table, name: "cp_items"))
        #expect(vm.gridPasteRows(from: "[{bad") == 0)
        #expect(vm.errorMessage != nil)
        #expect(vm.changeManager?.hasChanges == false)
    }

    // MARK: - MySQL

    @Test(.enabled(if: cpPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlCopyExecuteAndPasteSave() async throws {
        let port = try #require(cpPort("LODE_TEST_MYSQL_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "cp", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }

        _ = try await other.execute("DROP TABLE IF EXISTS cp_my", params: nil)
        _ = try await other.execute(
            "CREATE TABLE cp_my (id INT PRIMARY KEY, name VARCHAR(64), flag BOOLEAN DEFAULT FALSE, qty INT DEFAULT 7)",
            params: nil)
        defer { Task { _ = try? await other.execute("DROP TABLE IF EXISTS cp_my", params: nil) } }
        _ = try await other.execute("INSERT INTO cp_my (id, name, flag, qty) VALUES (1, 'first', 1, 3)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "cp_my", database: "testdb"))
        let result = try #require(vm.queryResult)
        #expect(result.rows.count == 1)
        #expect(vm.gridHasRowKey)

        // 复制 INSERT → 删除 → 执行 → 还原
        let insertSQL = try #require(vm.gridCopyText(rowKind: .insert, row: result.rows[0], columns: result.columns))
        #expect(insertSQL.contains("`testdb`.`cp_my`"))
        _ = try await other.execute("DELETE FROM cp_my WHERE id = 1", params: nil)
        _ = try await other.execute(insertSQL, params: nil)
        let restored = try await other.query("SELECT name, flag, qty FROM cp_my WHERE id = 1", params: nil)
        let restoredRow = try #require(restored.rows.first)
        #expect(cpText(restoredRow[0]) == "first")
        #expect(cpInt(restoredRow[1]) == 1)
        #expect(cpInt(restoredRow[2]) == 3)

        // 暂存编辑 → 复制 UPDATE → 执行 → 生效（含引号转义）
        vm.stageCellChange(column: "name", newValue: .string("O'Brien"), rowValues: result.rows[0], columns: result.columns)
        let updateSQL = try #require(vm.gridCopyText(rowKind: .update, row: result.rows[0], columns: result.columns))
        #expect(updateSQL.contains("'O''Brien'"))
        _ = try await other.execute(updateSQL, params: nil)
        let updated = try await other.query("SELECT name FROM cp_my WHERE id = 1", params: nil)
        #expect(cpText(try #require(updated.rows.first?.first)) == "O'Brien")
        vm.discardChanges()

        // 粘贴 JSON → 保存 → 缺键走 DEFAULT
        #expect(vm.gridPasteRows(from: "[{\"id\":2,\"name\":\"second\"},{\"id\":3}]") == 2)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        let pasted = try await other.query("SELECT name, qty, flag FROM cp_my WHERE id IN (2, 3) ORDER BY id", params: nil)
        #expect(pasted.rows.count == 2)
        #expect(cpText(pasted.rows[0][0]) == "second")
        #expect(cpInt(pasted.rows[0][1]) == 7)
        #expect(pasted.rows[1][0] == .null)
        #expect(cpInt(pasted.rows[1][1]) == 7)
        #expect(cpInt(pasted.rows[1][2]) == 0)

        // 无主键 MySQL 表：无行键 → 拒绝生成 UPDATE
        _ = try await other.execute("DROP TABLE IF EXISTS cp_my_nopk", params: nil)
        _ = try await other.execute("CREATE TABLE cp_my_nopk (a VARCHAR(16), b INT)", params: nil)
        defer { Task { _ = try? await other.execute("DROP TABLE IF EXISTS cp_my_nopk", params: nil) } }
        _ = try await other.execute("INSERT INTO cp_my_nopk (a, b) VALUES ('x', 1)", params: nil)
        await vm.openObject(DatabaseObject(kind: .table, name: "cp_my_nopk", database: "testdb"))
        #expect(vm.gridHasRowKey == false)
        let nopkResult = try #require(vm.queryResult)
        #expect(vm.gridCopyText(rowKind: .update, row: nopkResult.rows[0], columns: nopkResult.columns) == nil)
    }

    // MARK: - PostgreSQL

    @Test(.enabled(if: cpPort("LODE_TEST_PG_PORT") != nil))
    func pgCopyExecuteAndPasteSave() async throws {
        let port = try #require(cpPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "cp", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }

        _ = try await other.execute("DROP TABLE IF EXISTS cp_pg", params: nil)
        _ = try await other.execute(
            "CREATE TABLE cp_pg (id INT PRIMARY KEY, name TEXT, payload JSONB, qty INT DEFAULT 7)", params: nil)
        defer { Task { _ = try? await other.execute("DROP TABLE IF EXISTS cp_pg", params: nil) } }
        _ = try await other.execute(
            "INSERT INTO cp_pg (id, name, payload, qty) VALUES (1, 'first', '{\"a\":1}', 3)", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "cp_pg", schema: "public"))
        let result = try #require(vm.queryResult)
        #expect(result.rows.count == 1)
        #expect(vm.gridHasRowKey)

        // 复制 INSERT → 删除 → 执行 → 还原（JSONB 语义相等）
        let insertSQL = try #require(vm.gridCopyText(rowKind: .insert, row: result.rows[0], columns: result.columns))
        #expect(insertSQL.contains("\"public\".\"cp_pg\""))
        _ = try await other.execute("DELETE FROM cp_pg WHERE id = 1", params: nil)
        _ = try await other.execute(insertSQL, params: nil)
        let restored = try await other.query("SELECT name, payload, qty FROM cp_pg WHERE id = 1", params: nil)
        let restoredRow = try #require(restored.rows.first)
        #expect(cpText(restoredRow[0]) == "first")
        #expect(cpText(restoredRow[1]).map { $0.replacingOccurrences(of: " ", with: "") } == "{\"a\":1}")
        #expect(cpInt(restoredRow[2]) == 3)

        // 粘贴表头乱序 CSV → 保存 → 按名映射
        #expect(vm.gridPasteRows(from: "name,qty,id\nsecond,5,2") == 1)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        let pasted = try await other.query("SELECT name, qty FROM cp_pg WHERE id = 2", params: nil)
        let pastedRow = try #require(pasted.rows.first)
        #expect(cpText(pastedRow[0]) == "second")
        #expect(cpInt(pastedRow[1]) == 5)

        // 暂存编辑 → 复制 UPDATE → 执行 → 生效
        let fresh = try #require(vm.queryResult)
        let firstRow = try #require(fresh.rows.first { cpInt($0[0]) == 1 })
        vm.stageCellChange(column: "qty", newValue: .integer(9), rowValues: firstRow, columns: fresh.columns)
        let updateSQL = try #require(vm.gridCopyText(rowKind: .update, row: firstRow, columns: fresh.columns))
        #expect(updateSQL.contains("\"qty\" = 9"))
        _ = try await other.execute(updateSQL, params: nil)
        let updated = try await other.query("SELECT qty FROM cp_pg WHERE id = 1", params: nil)
        #expect(cpInt(try #require(updated.rows.first?.first)) == 9)
        vm.discardChanges()
        #expect(vm.changeManager?.hasChanges == false)
    }
}