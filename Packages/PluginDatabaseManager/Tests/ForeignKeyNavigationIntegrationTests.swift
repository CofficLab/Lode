import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-3 真实引擎验收（SQLite 外键表）：
// - PRAGMA 外键内省 → foreignKey(for:) 命中；
// - 引用选择器按非键列（name）搜索、空搜索全量按键排序、通配符按字面量处理；
// - 跳转到引用行：打开引用表并带定位过滤，结果恰为被引用行；
// - 跳转使用已暂存（未保存）的显示值；
// - 选值 → 暂存 → 保存 → 子表外键更新；
// - NULL 外键不可定位（跳转为无操作）。

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ForeignKeyNavigationIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    @Test func sqliteForeignKeyPickerAndJump() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-fk-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "fk", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }

        _ = try await other.execute(
            "CREATE TABLE fk_parents (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", params: nil)
        _ = try await other.execute(
            "CREATE TABLE fk_children (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES fk_parents(id), label TEXT)",
            params: nil)
        _ = try await other.execute(
            "INSERT INTO fk_parents (id, name) VALUES (1, 'Alpha'), (2, 'Beta'), (3, 'Gamma')", params: nil)
        _ = try await other.execute(
            "INSERT INTO fk_children (id, parent_id, label) VALUES (10, 2, 'child')", params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "fk_children"))
        #expect(vm.queryResult?.rows.count == 1)

        // 外键内省
        let fk = try #require(vm.foreignKey(for: "parent_id"))
        #expect(fk.referencesTable == "fk_parents")
        #expect(fk.referencesColumns == ["id"])
        #expect(vm.foreignKey(for: "label") == nil)

        // 按非键列搜索（name 命中 Alpha）
        let options = try await vm.fetchReferenceOptions(column: "parent_id", search: "alp")
        #expect(options.count == 1)
        #expect(options[0].keyValue == .integer(1))
        #expect(options[0].preview.contains("Alpha"))

        // 空搜索：全量按键升序
        let all = try await vm.fetchReferenceOptions(column: "parent_id", search: "")
        #expect(all.map(\.keyValue) == [.integer(1), .integer(2), .integer(3)])

        // LIKE 通配符按字面量处理，不匹配任何行
        let wildcards = try await vm.fetchReferenceOptions(column: "parent_id", search: "%")
        #expect(wildcards.isEmpty)

        // 跳转到引用行：parent_id = 2 → Beta
        let row = try #require(vm.queryResult?.rows.first)
        let columns = try #require(vm.queryResult?.columns)
        await vm.jumpToReference(column: "parent_id", rowValues: row, columns: columns)
        #expect(vm.openTableObject?.name == "fk_parents")
        #expect(vm.tableFilter.isActive)
        #expect(vm.showFilterPanel)
        let jumped = try #require(vm.queryResult)
        #expect(jumped.rows == [[.integer(2), .string("Beta")]])

        // 回到子表：选值 → 暂存 → 保存 → 数据库更新
        await vm.openObject(DatabaseObject(kind: .table, name: "fk_children"))
        let childRow = try #require(vm.queryResult?.rows.first)
        let childColumns = try #require(vm.queryResult?.columns)
        vm.stageCellChange(column: "parent_id", newValue: .integer(3), rowValues: childRow, columns: childColumns)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        let saved = try await other.query("SELECT parent_id FROM fk_children WHERE id = 10", params: nil)
        #expect(saved.rows.first?.first == .integer(3))

        // 跳转使用暂存（未保存）的显示值：staged parent_id = 1 → Alpha
        let freshRow = try #require(vm.queryResult?.rows.first)
        vm.stageCellChange(column: "parent_id", newValue: .integer(1), rowValues: freshRow, columns: childColumns)
        await vm.jumpToReference(column: "parent_id", rowValues: freshRow, columns: childColumns)
        #expect(vm.openTableObject?.name == "fk_parents")
        #expect(vm.queryResult?.rows == [[.integer(1), .string("Alpha")]])

        // NULL 外键不可定位：跳转为无操作
        _ = try await other.execute(
            "INSERT INTO fk_children (id, parent_id, label) VALUES (11, NULL, 'orphan')", params: nil)
        await vm.openObject(DatabaseObject(kind: .table, name: "fk_children"))
        let rows = try #require(vm.queryResult?.rows)
        #expect(rows.count == 2)
        let orphan = rows[1]
        await vm.jumpToReference(column: "parent_id", rowValues: orphan, columns: childColumns)
        #expect(vm.openTableObject?.name == "fk_children")
        #expect(vm.queryResult?.rows.count == 2)

        _ = try await other.execute("DROP TABLE IF EXISTS fk_children", params: nil)
        _ = try await other.execute("DROP TABLE IF EXISTS fk_parents", params: nil)
        await vm.disconnect()
    }
}