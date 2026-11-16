import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-6 列布局持久化验收：用户调整的列宽/列序在关闭并重新打开同一表后恢复。
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct GridLayoutPersistenceIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    @Test func layoutPersistsAcrossReopen() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-gl-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "gl", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE gl_items (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)", params: nil)
        _ = try await other.execute("INSERT INTO gl_items (id, name, qty) VALUES (1, 'a', 5)", params: nil)

        let object = DatabaseObject(kind: .table, name: "gl_items")
        let key = "DatabaseManager.gridLayout.\(config.id.uuidString).\(object.id)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        await vm.openObject(object)
        vm.setGridColumnWidth("name", width: 200)
        vm.moveGridColumn("qty", left: true)
        #expect(vm.gridColumnWidths["name"] == 200)
        #expect(vm.gridColumnOrder == ["id", "qty", "name"])
        // 宽度钳制到上限
        vm.setGridColumnWidth("id", width: 9999)
        #expect(vm.gridColumnWidths["id"] == GridColumnLayout.maxWidth)

        // 关闭并重新打开 → 从 UserDefaults 恢复
        vm.closeTableBrowser()
        await vm.openObject(object)
        #expect(vm.gridColumnWidths["name"] == 200)
        #expect(vm.gridColumnWidths["id"] == GridColumnLayout.maxWidth)
        #expect(vm.gridColumnOrder == ["id", "qty", "name"])
    }
}