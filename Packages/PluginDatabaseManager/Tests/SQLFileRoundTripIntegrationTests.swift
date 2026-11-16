import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-6 SQL 文件往返（VM 逻辑层，临时文件，无头）：
// 打开为文件标签、⌘S 写回、外部变更冲突、Reload / Save As / Keep Editing 分支、持久化往返。
// 面板（NSOpenPanel/NSSavePanel）属 UI，不在此覆盖；逻辑方法直接接收 URL。

@MainActor
@Suite(.serialized)
struct SQLFileRoundTripIntegrationTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.sqlfile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeVM(_ defaults: UserDefaults) -> DatabaseViewModel {
        DatabaseViewModel(loadSavedConfigs: false, manager: DatabaseManagerCore(), workspaceDefaults: defaults)
    }

    private func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lode-sqlrt-\(UUID().uuidString)-\(name).sql")
    }

    @Test func openCreatesFileBackedCleanTab() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("open"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        #expect(vm.workspace.activeTab.fileURL == url)
        #expect(vm.workspace.activeTab.isFileBacked)
        #expect(vm.queryText == "SELECT 1;")
        #expect(vm.workspace.activeTab.isDirty == false)
        #expect(vm.workspace.activeTab.title == url.lastPathComponent)
        #expect(vm.openTableObject == nil)
        #expect(vm.sqlFileConflict == nil)
    }

    @Test func saveWritesBackAndClearsDirty() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("save"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        vm.queryText = "SELECT 2;"
        vm.saveActiveSQLFile()
        #expect(try SQLFileStore.read(url) == "SELECT 2;")
        #expect(vm.workspace.activeTab.isDirty == false)
        #expect(vm.sqlFileConflict == nil)
    }

    @Test func selfSaveDoesNotRaiseConflict() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("selfsave"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        vm.queryText = "SELECT 2;"
        vm.saveActiveSQLFile()
        vm.refreshExternalChangeState()
        #expect(vm.sqlFileConflict == nil)
    }

    @Test func externalChangeRaisesCleanConflict() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("ext"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        try SQLFileStore.write("SELECT 999;", to: url)
        vm.refreshExternalChangeState()
        #expect(vm.sqlFileConflict?.change == .modified)
        #expect(vm.sqlFileConflict?.isDirty == false)
        #expect(vm.sqlFileConflict?.url == url)
    }

    @Test func externalChangeWithLocalEditsIsDirtyConflict() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("extdirty"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        vm.queryText = "SELECT 2;"
        try SQLFileStore.write("SELECT 999;", to: url)
        vm.refreshExternalChangeState()
        #expect(vm.sqlFileConflict?.change == .modified)
        #expect(vm.sqlFileConflict?.isDirty == true)
    }

    @Test func reloadAdoptsDiskAndClearsConflict() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("reload"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        vm.queryText = "LOCAL EDIT;"
        try SQLFileStore.write("SELECT 999;", to: url)
        vm.refreshExternalChangeState()
        #expect(vm.sqlFileConflict != nil)
        vm.reloadActiveSQLFile()
        #expect(vm.queryText == "SELECT 999;")
        #expect(vm.workspace.activeTab.isDirty == false)
        #expect(vm.sqlFileConflict == nil)
    }

    @Test func saveAsReassociatesAndLeavesOriginal() throws {
        let vm = makeVM(makeDefaults())
        let urlA = tempURL("orig"); let urlB = tempURL("new")
        defer { try? FileManager.default.removeItem(at: urlA); try? FileManager.default.removeItem(at: urlB) }
        try SQLFileStore.write("SELECT 1;", to: urlA)
        vm.openSQLFile(at: urlA)
        vm.queryText = "LOCAL EDIT;"
        try SQLFileStore.write("EXTERNAL;", to: urlA)
        vm.saveActiveSQLFile(as: urlB)
        #expect(try SQLFileStore.read(urlB) == "LOCAL EDIT;")
        #expect(try SQLFileStore.read(urlA) == "EXTERNAL;")
        #expect(vm.workspace.activeTab.fileURL == urlB)
        #expect(vm.workspace.activeTab.isDirty == false)
        #expect(vm.sqlFileConflict == nil)
    }

    @Test func missingFileRaisesMissing() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("missing"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        try FileManager.default.removeItem(at: url)
        vm.refreshExternalChangeState()
        #expect(vm.sqlFileConflict?.change == .missing)
    }

    @Test func dismissAcknowledgesBaselineAndKeepsEdits() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("dismiss"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        vm.queryText = "LOCAL EDIT;"
        try SQLFileStore.write("EXTERNAL;", to: url)
        vm.refreshExternalChangeState()
        #expect(vm.sqlFileConflict != nil)
        vm.dismissSQLFileConflict()
        #expect(vm.sqlFileConflict == nil)
        #expect(vm.queryText == "LOCAL EDIT;")
        vm.refreshExternalChangeState()
        #expect(vm.sqlFileConflict == nil)
    }

    @Test func touchWithoutContentChangeIsNotConflict() throws {
        let vm = makeVM(makeDefaults())
        let url = tempURL("touch"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        vm.openSQLFile(at: url)
        // 仅改 mtime，内容不变（touch）：不应误报冲突。
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        vm.refreshExternalChangeState()
        #expect(vm.sqlFileConflict == nil)
    }

    @Test func persistedFileAssociationRoundTrip() throws {
        let defaults = makeDefaults()
        let url = tempURL("persist"); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        let vm = makeVM(defaults)
        vm.openSQLFile(at: url)
        vm.workspace.persist()
        let vm2 = makeVM(defaults)
        #expect(vm2.workspace.activeTab.fileURL == url)
        #expect(vm2.workspace.activeTab.fileBaseline != nil)
        #expect(vm2.queryText == "SELECT 1;")
        vm2.refreshExternalChangeState()
        #expect(vm2.sqlFileConflict == nil)
    }
}