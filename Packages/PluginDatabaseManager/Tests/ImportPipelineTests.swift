import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-4b 离线管线单测（SQLite 隔离临时库，始终运行）：
// 预览/推断、映射导入、坏行跳过/中止（转换失败 + 约束冲突经保存点逐行定位）、
// 建新表路径、JSON 导入、readOnly 拒绝、confirmWrites 取消/确认、中途取消整体回滚。

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ImportPipelineTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).\(ext)")
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    private func connect(_ vm: DatabaseViewModel, path: String, safeMode: ConnectionSafeMode = .off) async {
        await vm.connect(config: DatabaseConfig(name: "imp", type: .sqlite, database: path).withSafeMode(safeMode))
    }

    private func waitForConfirmation(_ vm: DatabaseViewModel) async -> Bool {
        for _ in 0..<5000 {
            if vm.writeConfirmation != nil { return true }
            await Task.yield()
        }
        return false
    }

    private func count(_ other: SQLiteConnection, _ table: String) async throws -> Int {
        let result = try await other.query("SELECT COUNT(*) FROM \(table)", params: nil)
        guard case .integer(let n) = result.rows.first?.first else { return -1 }
        return n
    }

    // MARK: - 预览与推断

    @Test func previewDetectsHeaderColumnsAndTypes() async throws {
        let (vm, _) = await makeSUT()
        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("id,name,score\n1,a,1.5\n2,b,2.5\n", to: url)
        await vm.loadImportPreview(url: url)
        #expect(vm.importError == nil)
        #expect(vm.importFormat == .csv)
        #expect(vm.importSourceColumns == ["id", "name", "score"])
        #expect(vm.importPreviewRows.count == 2)
        #expect(vm.importInferredTypes == [.integer, .text, .double])
    }

    @Test func previewWithoutHeaderGeneratesColumnNames() async throws {
        let (vm, _) = await makeSUT()
        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("1,a\n2,b\n", to: url)
        vm.importHasHeader = false
        await vm.loadImportPreview(url: url)
        #expect(vm.importSourceColumns == ["Column 1", "Column 2"])
        #expect(vm.importPreviewRows.count == 2)
    }

    // MARK: - 导入现有表

    @Test func importCSVIntoExistingTableWithMappingAndSkip() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_t (id INTEGER PRIMARY KEY, label TEXT)", params: nil)
        await connect(vm, path: path)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("id,label,extra\n1,one,x\n2,two,y\n3,three,z\n", to: url)
        await vm.loadImportPreview(url: url)
        let mappings = ImportMappingBuilder.autoMap(
            sourceColumns: vm.importSourceColumns,
            targetColumns: ["id", "label"],
            samples: [["1", "one", "x"], ["2", "two", "y"]]
        )
        #expect(mappings.map(\.targetColumn) == ["id", "label", nil])
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_t")), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importCompleted)
        #expect(vm.importedRowCount == 3)
        #expect(vm.importProgress == 1)
        #expect(try await count(other, "imp_t") == 3)
        let label = try await other.query("SELECT label FROM imp_t WHERE id=2", params: nil).rows.first?.first
        #expect(label == .string("two"))
        await vm.disconnect()
    }

    @Test func conversionBadRowSkippedAndReported() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_t (id INTEGER, label TEXT)", params: nil)
        await connect(vm, path: path)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("id,label\n1,ok\nabc,bad\n3,ok\n", to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [
            ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "label", targetColumn: "label", inferredType: .text),
        ]
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_t")), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importedRowCount == 2)
        #expect(vm.importBadRows.count == 1)
        #expect(vm.importBadRows[0].rowNumber == 2)
        #expect(try await count(other, "imp_t") == 2)
        await vm.disconnect()
    }

    @Test func conversionBadRowAbortRollsBackEverything() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_t (id INTEGER, label TEXT)", params: nil)
        await connect(vm, path: path)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("id,label\n1,ok\nabc,bad\n3,ok\n", to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [
            ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "label", targetColumn: "label", inferredType: .text),
        ]
        vm.startImport(
            target: .existingTable(DatabaseObject(kind: .table, name: "imp_t")),
            mappings: mappings,
            options: ImportOptions(badRowStrategy: .abort)
        )
        await vm.waitForImport()
        #expect(vm.importError != nil)
        #expect(vm.importCompleted == false)
        #expect(try await count(other, "imp_t") == 0)
        await vm.disconnect()
    }

    @Test func constraintViolationIsolatedPerRowViaSavepoints() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_t (id INTEGER PRIMARY KEY, label TEXT UNIQUE)", params: nil)
        _ = try await other.execute("INSERT INTO imp_t VALUES (99, 'dup')", params: nil)
        await connect(vm, path: path)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        // 第 2 行 label 与既有行冲突：整批失败后逐行重试，仅该行记为坏行。
        try write("id,label\n1,one\n2,dup\n3,three\n", to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [
            ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "label", targetColumn: "label", inferredType: .text),
        ]
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_t")), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importedRowCount == 2)
        #expect(vm.importBadRows.count == 1)
        #expect(vm.importBadRows[0].rowNumber == 2)
        #expect(try await count(other, "imp_t") == 3)
        await vm.disconnect()
    }

    // MARK: - 建新表路径

    @Test func importCreatesNewTableFromDraft() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        await connect(vm, path: path)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("id,score\n1,1.5\n2,2.5\n", to: url)
        await vm.loadImportPreview(url: url)
        let mappings = ImportMappingBuilder.autoMap(
            sourceColumns: vm.importSourceColumns,
            targetColumns: vm.importSourceColumns,
            samples: [["1", "1.5"], ["2", "2.5"]]
        )
        let draft = ImportMappingBuilder.newTableDraft(name: "imp_new", mappings: mappings)
        vm.startImport(target: .newTable(draft), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importCompleted)
        #expect(vm.openTableObject?.name == "imp_new")
        #expect(try await count(other, "imp_new") == 2)
        let types = try await other.query("PRAGMA table_info(imp_new)", params: nil).rows.compactMap { $0.count > 2 ? $0[2].description : nil }
        #expect(types == ["INTEGER", "REAL"])
        await vm.disconnect()
    }

    // MARK: - JSON

    @Test func importJSONIntoExistingTable() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_t (id INTEGER, label TEXT)", params: nil)
        await connect(vm, path: path)

        let url = tempURL("json")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("[{\"id\":1,\"label\":\"a\"},{\"id\":2,\"label\":null}]", to: url)
        await vm.loadImportPreview(url: url)
        #expect(vm.importFormat == .json)
        let mappings = [
            ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "label", targetColumn: "label", inferredType: .text),
        ]
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_t")), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importedRowCount == 2)
        let nullLabel = try await other.query("SELECT label FROM imp_t WHERE id=2", params: nil).rows.first?.first
        #expect(nullLabel == .null)
        await vm.disconnect()
    }

    // MARK: - 写闸门

    @Test func readOnlyBlocksImport() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_t (id INTEGER)", params: nil)
        await connect(vm, path: path, safeMode: .readOnly)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("id\n1\n2\n", to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer)]
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_t")), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError != nil)
        #expect(vm.importCompleted == false)
        #expect(try await count(other, "imp_t") == 0)
        await vm.disconnect()
    }

    @Test func confirmWritesCancelAndApprove() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_t (id INTEGER)", params: nil)
        await connect(vm, path: path, safeMode: .confirmWrites)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try write("id\n1\n2\n", to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer)]
        let target = ImportTarget.existingTable(DatabaseObject(kind: .table, name: "imp_t"))

        vm.startImport(target: target, mappings: mappings)
        #expect(await waitForConfirmation(vm))
        #expect(vm.writeConfirmation?.kind == .batch)
        vm.resolveWriteConfirmation(false)
        await vm.waitForImport()
        #expect(vm.importCompleted == false)
        #expect(try await count(other, "imp_t") == 0)

        vm.startImport(target: target, mappings: mappings)
        #expect(await waitForConfirmation(vm))
        vm.resolveWriteConfirmation(true)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(try await count(other, "imp_t") == 2)
        await vm.disconnect()
    }

    // MARK: - 取消

    @Test func cancelMidImportRollsBackEverything() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-imp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_t (id INTEGER, label TEXT)", params: nil)
        await connect(vm, path: path)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        var text = "id,label\n"
        for i in 0..<50_000 { text += "\(i),row\(i)\n" }
        try write(text, to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [
            ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "label", targetColumn: "label", inferredType: .text),
        ]
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_t")), mappings: mappings)
        var started = false
        for _ in 0..<200_000 {
            if vm.importedRowCount > 0 { started = true; break }
            await Task.yield()
        }
        #expect(started)
        vm.cancelImport()
        await vm.waitForImport()
        #expect(vm.importCompleted == false)
        #expect(vm.importError != nil)
        #expect(try await count(other, "imp_t") == 0)
        await vm.disconnect()
    }
}