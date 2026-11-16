import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-5b 离线管线单测（SQLite 隔离临时库，始终运行）：
// 当前页直写、全部行 keyset/OFFSET 流式分页、筛选结果范围、空表仅表头、
// JSON/SQL/Markdown 经管线往返、中途取消删除半成品文件、预设注入 UserDefaults 往返。

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ExportPipelineTests {
    private func makeSUT(defaults: UserDefaults = .standard) async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager, workspaceDefaults: defaults)
        return (viewModel, manager)
    }

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "lode-exp-\(UUID().uuidString).\(ext)")
    }

    private func tempDB() -> String {
        NSTemporaryDirectory() + "lode-exp-\(UUID().uuidString).sqlite"
    }

    private func connect(_ vm: DatabaseViewModel, path: String) async {
        await vm.connect(config: DatabaseConfig(name: "exp", type: .sqlite, database: path))
    }

    /// 流式统计文件行数（按 \n；测试数据不含内嵌换行）。
    private func countLines(_ url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var count = 0
        while true {
            guard let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty else { break }
            count += chunk.filter { $0 == 0x0A }.count
        }
        return count
    }

    private func seed(_ other: SQLiteConnection, table: String, rows: Int, primaryKey: Bool = true) async throws {
        let ddl = primaryKey
            ? "CREATE TABLE \(table) (id INTEGER PRIMARY KEY, label TEXT)"
            : "CREATE TABLE \(table) (id INTEGER, label TEXT)"
        _ = try await other.execute(ddl, params: nil)
        _ = try await other.execute(
            "WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM seq WHERE x<\(rows)) INSERT INTO \(table) (id, label) SELECT x, 'row'||x FROM seq",
            params: nil)
    }

    // MARK: - 当前页

    @Test func currentPageExportsLoadedRowsOnly() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        try await seed(other, table: "ex_page", rows: 50)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_page"))
        await vm.setPageSize(5)
        #expect(vm.queryResult?.rows.count == 5)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .currentPage
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportError == nil)
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 5)
        #expect(vm.exportProgress == 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = GridPasteParser.parseCSV(text)
        #expect(parsed.first == ["id", "label"])
        #expect(parsed.count == 6)
        #expect(parsed[1].first == "1")
    }

    @Test func currentPageWithoutResultReportsNoData() async throws {
        let (vm, _) = await makeSUT()
        await connect(vm, path: ":memory:")
        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportRange = .currentPage
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportCompleted == false)
        #expect(vm.exportError != nil)
    }

    // MARK: - 全部行（keyset / OFFSET）

    @Test func allRowsKeysetStreamsEveryRowAcrossPages() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        try await seed(other, table: "ex_big", rows: 12000)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_big"))

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportError == nil)
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 12000)
        #expect(try countLines(url) == 12001)
        // 抽样首尾行值正确（keyset 升序遍历无间隙、无重复）。
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = String(decoding: try handle.read(upToCount: 64) ?? Data(), as: UTF8.self)
        #expect(head.hasPrefix("id,label\r\n1,row1\r\n"))
    }

    @Test func allRowsWithoutPrimaryKeyUsesOffsetPaging() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        try await seed(other, table: "ex_nopk", rows: 12000, primaryKey: false)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_nopk"))
        // 无主键：导出列不含 rowid 辅助列。
        #expect(vm.selectedTableSchema?.columns.map(\.name) == ["id", "label"])

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportError == nil)
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 12000)
        #expect(try countLines(url) == 12001)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("id,label\r\n"))
        #expect(text.contains("rowid") == false)
    }

    // MARK: - 筛选结果

    @Test func filteredRowsRespectsTableFilter() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        try await seed(other, table: "ex_filter", rows: 100)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_filter"))
        vm.tableFilter = TableFilter(conditions: [FilterCondition(column: "id", op: .greaterThan, operands: ["90"])])
        await vm.applyFilter()

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .filteredRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportError == nil)
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 10)
        #expect(try countLines(url) == 11)
        let parsed = GridPasteParser.parseCSV(try String(contentsOf: url, encoding: .utf8))
        let ids = parsed.dropFirst().compactMap { $0.first }
        #expect(ids.sorted() == (91...100).map { String($0) }.sorted())
    }

    // MARK: - 空表

    @Test func emptyTableExportsHeaderOnly() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ex_empty (id INTEGER PRIMARY KEY, label TEXT)", params: nil)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_empty"))

        let csvURL = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: csvURL) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        vm.startExport(to: csvURL)
        await vm.waitForExport()
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 0)
        #expect(try String(contentsOf: csvURL, encoding: .utf8) == "id,label\r\n")

        let jsonURL = tempURL("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        vm.exportFormat = .json
        vm.startExport(to: jsonURL)
        await vm.waitForExport()
        #expect(vm.exportCompleted)
        let array = try JSONSerialization.jsonObject(with: try Data(contentsOf: jsonURL)) as? [Any]
        #expect(array?.isEmpty == true)
    }

    // MARK: - 格式经管线往返

    @Test func jsonAllRowsParsesBackToTypedValues() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ex_json (id INTEGER PRIMARY KEY, label TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO ex_json (id, label) VALUES (1, 'alpha'), (2, 'beta'), (3, NULL)", params: nil)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_json"))

        let url = tempURL("json")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .json
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportCompleted)
        let array = try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [[String: Any]])
        #expect(array.count == 3)
        #expect(array[0]["id"] as? Int == 1)
        #expect(array[0]["label"] as? String == "alpha")
        #expect(array[2]["label"] is NSNull)
    }

    @Test func sqlInsertAllRowsExecutesIntoFreshTable() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ex_src (id INTEGER PRIMARY KEY, label TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO ex_src (id, label) VALUES (1, 'O''Brien'), (2, 'say \"hi\"'), (3, '中文')", params: nil)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_src"))

        let url = tempURL("sql")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .sqlInsert
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportCompleted)
        let text = try String(contentsOf: url, encoding: .utf8)
        _ = try await other.execute("CREATE TABLE ex_dst (id INTEGER PRIMARY KEY, label TEXT)", params: nil)
        // 字面量内含引号/换行，按语句解析器切分而非裸换行。
        for statement in SQLStatementParser.split(text) {
            let rewritten = statement.replacingOccurrences(of: "\"ex_src\"", with: "\"ex_dst\"")
            _ = try await other.execute(rewritten, params: nil)
        }
        let result = try await other.query("SELECT id, label FROM ex_dst ORDER BY id", params: nil)
        #expect(result.rows.count == 3)
        #expect(result.rows[0][1].description == "O'Brien")
        #expect(result.rows[2][1].description == "中文")
    }

    @Test func markdownAllRowsMatchesWholeTableFormat() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ex_md (id INTEGER PRIMARY KEY, label TEXT)", params: nil)
        _ = try await other.execute("INSERT INTO ex_md (id, label) VALUES (1, 'a|b'), (2, NULL)", params: nil)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_md"))

        let url = tempURL("md")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .markdown
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportCompleted)
        let streamed = try String(contentsOf: url, encoding: .utf8)
        let whole = GridCopyFormat.markdownTable(
            columns: ["id", "label"],
            rows: [[.integer(1), .string("a|b")], [.integer(2), .null]]) + "\n"
        #expect(streamed == whole)
    }

    // MARK: - 取消

    @Test func cancelMidExportRemovesPartialFile() async throws {
        let path = tempDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        try await seed(other, table: "ex_cancel", rows: 200000)
        let (vm, _) = await makeSUT()
        await connect(vm, path: path)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_cancel"))

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        vm.startExport(to: url)
        // 等到首页写盘后立即取消，确保落在流式中途。
        for _ in 0..<40000 {
            if vm.exportedRowCount > 0 { break }
            await Task.yield()
        }
        vm.cancelExport()
        await vm.waitForExport()
        #expect(vm.exportCompleted == false)
        #expect(vm.isExporting == false)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(vm.exportError != nil)
    }

    // MARK: - 预设

    @Test func presetsRoundTripViaInjectedDefaults() async throws {
        let suiteName = "lode-export-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (vm, _) = await makeSUT(defaults: defaults)
        vm.presentExport()
        #expect(vm.exportPresets.isEmpty)

        vm.exportFormat = .json
        vm.exportRange = .filteredRows
        vm.saveExportPreset(name: "  Filtered JSON  ")
        #expect(vm.exportPresets.count == 1)
        #expect(vm.exportPresets[0].name == "Filtered JSON")
        #expect(vm.exportPresets[0].format == .json)
        #expect(vm.exportPresets[0].range == .filteredRows)

        // 同名替换而非追加。
        vm.exportFormat = .csv
        vm.saveExportPreset(name: "Filtered JSON")
        #expect(vm.exportPresets.count == 1)
        #expect(vm.exportPresets[0].format == .csv)

        // 空白名忽略。
        vm.saveExportPreset(name: "   ")
        #expect(vm.exportPresets.count == 1)

        // 新 VM 从同一 suite 载入。
        let (vm2, _) = await makeSUT(defaults: defaults)
        vm2.presentExport()
        #expect(vm2.exportPresets.count == 1)
        let preset = try #require(vm2.exportPresets.first)
        vm2.exportFormat = .markdown
        vm2.exportRange = .currentPage
        vm2.applyExportPreset(preset)
        #expect(vm2.exportFormat == .csv)
        #expect(vm2.exportRange == .filteredRows)

        vm2.deleteExportPreset(id: preset.id)
        #expect(vm2.exportPresets.isEmpty)
        let (vm3, _) = await makeSUT(defaults: defaults)
        vm3.presentExport()
        #expect(vm3.exportPresets.isEmpty)
    }
}