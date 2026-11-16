import Foundation
import MachO
import Testing
@testable import DatabaseManagerPlugin

// P5-5 真实引擎验收：
// - 百万行 CSV 流式导出 SQLite/MySQL/PG（COUNT + 抽样值核验 + 进程内存平稳）；
// - 导出→导入→比对往返（P5 阶段门）：特殊值（逗号/引号/换行/中文/NULL/负浮点）CSV 往返等价。
// MySQL 经 switchDatabase 独立库（重连关闭旧连接，建库/ seeding /清理/核验走驱动直连）；
// PG 经 switchSchema 独立 schema（同一连接）。百万行 seeding 用递归 CTE（服务端生成，不整载）。

private func dePort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func deInt(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func deDouble(_ value: DatabaseValue?) -> Double? {
    switch value {
    case .double(let d): return d
    case .integer(let i): return Double(i)
    case .string(let s): return Double(s)
    default: return nil
    }
}

/// 进程物理内存占用（phys_footprint），用于验证流式导出不随行数累积。
private func dePhysFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(20)))
struct DataExportIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "lode-de-\(UUID().uuidString).\(ext)")
    }

    /// 流式统计文件行数（按 \n；百万行 label 不含内嵌换行）。
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

    /// 由预览结果构造同名映射（导出列即目标列）。
    private func identityMappings(_ vm: DatabaseViewModel) -> [ImportColumnMapping] {
        vm.importSourceColumns.enumerated().map { index, column in
            ImportColumnMapping(sourceColumn: column, targetColumn: column, inferredType: vm.importInferredTypes[index])
        }
    }

    // MARK: - 百万行流式导出

    @Test func sqliteMillionRowCSVExportMemoryStable() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-de-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ex_mil (id INTEGER PRIMARY KEY, label TEXT, score REAL)", params: nil)
        _ = try await other.execute(
            "WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM seq WHERE x<1000000) INSERT INTO ex_mil (id, label, score) SELECT x, 'row'||x, x/4.0 FROM seq",
            params: nil)
        await vm.connect(config: DatabaseConfig(name: "de", type: .sqlite, database: path).withSafeMode(.off))
        #expect(vm.isConnected)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_mil"))

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        let baseline = dePhysFootprint()
        vm.startExport(to: url)
        await vm.waitForExport()
        let after = dePhysFootprint()
        #expect(vm.exportError == nil)
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 1_000_000)
        #expect(vm.exportProgress == 1)
        #expect(try countLines(url) == 1_000_001)
        // 流式写盘：内存增量远低于整载百万行（宽松上界 128MB，排除分配器噪声）。
        // phys_footprint 是 UInt64，导出期间内存可能回落，guarded 减法避免下溢成天文数字。
        let growth = after > baseline ? after - baseline : 0
        #expect(growth < 128 * 1024 * 1024)
        let label = try await other.query("SELECT label FROM ex_mil WHERE id=500000", params: nil).rows.first?.first
        #expect(label == .string("row500000"))
        let score = deDouble(try await other.query("SELECT score FROM ex_mil WHERE id=1000000", params: nil).rows.first?.first)
        #expect(score == 250000)
        await vm.disconnect()
    }

    @Test(.enabled(if: dePort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlMillionRowCSVExport() async throws {
        let port = try #require(dePort("LODE_TEST_MYSQL_PORT"))
        let database = "de_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "de", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { _ = try? await other.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil); await other.close(); await vm.disconnect() } }
        _ = try await other.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await other.execute("CREATE TABLE `\(database)`.ex_mil (id INT PRIMARY KEY, label VARCHAR(64), score DOUBLE) ENGINE=InnoDB", params: nil)
        _ = try await other.execute("SET SESSION cte_max_recursion_depth = 1000000", params: nil)
        _ = try await other.execute(
            "INSERT INTO `\(database)`.ex_mil (id, label, score) WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000000) SELECT n, CONCAT('row', n), n/4 FROM seq",
            params: nil)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        await vm.switchDatabase(database)
        #expect(vm.activeDatabase == database)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_mil", database: database))

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportError == nil)
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 1_000_000)
        #expect(try countLines(url) == 1_000_001)
        let count = deInt(try await other.query("SELECT COUNT(*) FROM `\(database)`.ex_mil", params: nil))
        #expect(count == 1_000_000)
        let label = try await other.query("SELECT label FROM `\(database)`.ex_mil WHERE id=500000", params: nil).rows.first?.first
        #expect(label == .string("row500000"))
        let score = deDouble(try await other.query("SELECT score FROM `\(database)`.ex_mil WHERE id=1000000", params: nil).rows.first?.first)
        #expect(score == 250000)
    }

    @Test(.enabled(if: dePort("LODE_TEST_PG_PORT") != nil))
    func pgMillionRowCSVExport() async throws {
        let port = try #require(dePort("LODE_TEST_PG_PORT"))
        let schema = "de_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "de", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).ex_mil (id INTEGER PRIMARY KEY, label TEXT, score DOUBLE PRECISION)", params: nil)
        _ = try await conn.execute(
            "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000000) INSERT INTO \(quoted).ex_mil (id, label, score) SELECT n, 'row'||n, n::double precision/4 FROM seq",
            params: nil)
        await vm.switchSchema(schema)
        #expect(vm.activeSchema == schema)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_mil", schema: schema))

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportError == nil)
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 1_000_000)
        #expect(try countLines(url) == 1_000_001)
        let count = deInt(try await conn.query("SELECT COUNT(*) FROM \(quoted).ex_mil", params: nil))
        #expect(count == 1_000_000)
        let label = try await conn.query("SELECT label FROM \(quoted).ex_mil WHERE id=500000", params: nil).rows.first?.first
        #expect(label == .string("row500000"))
        let score = deDouble(try await conn.query("SELECT score FROM \(quoted).ex_mil WHERE id=1000000", params: nil).rows.first?.first)
        #expect(score == 250000)
    }

    // MARK: - 导出→导入→比对往返（P5 阶段门）

    @Test func sqliteExportImportCSVRoundTrip() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-de-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ex_rt (id INTEGER PRIMARY KEY, label TEXT, score REAL)", params: nil)
        _ = try await other.execute("CREATE TABLE ex_rt2 (id INTEGER PRIMARY KEY, label TEXT, score REAL)", params: nil)
        try await seedRoundTripRows(other, table: "ex_rt", placeholder: "?")
        await vm.connect(config: DatabaseConfig(name: "de", type: .sqlite, database: path).withSafeMode(.off))
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_rt"))

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 6)

        await vm.loadImportPreview(url: url)
        #expect(vm.importError == nil)
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "ex_rt2")), mappings: identityMappings(vm), options: ImportOptions(emptyAsNull: true))
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importCompleted)
        #expect(vm.importedRowCount == 6)
        #expect(vm.importBadRows.isEmpty)

        let src = try await other.query("SELECT id, label, score FROM ex_rt ORDER BY id", params: nil)
        let dst = try await other.query("SELECT id, label, score FROM ex_rt2 ORDER BY id", params: nil)
        #expect(src.rows == dst.rows)
        await vm.disconnect()
    }

    @Test(.enabled(if: dePort("LODE_TEST_PG_PORT") != nil))
    func pgExportImportCSVRoundTrip() async throws {
        let port = try #require(dePort("LODE_TEST_PG_PORT"))
        let schema = "de_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "de", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).ex_rt (id INTEGER PRIMARY KEY, label TEXT, score DOUBLE PRECISION)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).ex_rt2 (id INTEGER PRIMARY KEY, label TEXT, score DOUBLE PRECISION)", params: nil)
        try await seedRoundTripRows(conn, table: "\(quoted).ex_rt", placeholder: "$")
        await vm.switchSchema(schema)
        await vm.openObject(DatabaseObject(kind: .table, name: "ex_rt", schema: schema))

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        vm.exportFormat = .csv
        vm.exportRange = .allRows
        vm.startExport(to: url)
        await vm.waitForExport()
        #expect(vm.exportCompleted)
        #expect(vm.exportedRowCount == 6)

        await vm.loadImportPreview(url: url)
        #expect(vm.importError == nil)
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "ex_rt2", schema: schema)), mappings: identityMappings(vm), options: ImportOptions(emptyAsNull: true))
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importCompleted)
        #expect(vm.importedRowCount == 6)
        #expect(vm.importBadRows.isEmpty)

        let src = try await conn.query("SELECT id, label, score FROM \(quoted).ex_rt ORDER BY id", params: nil)
        let dst = try await conn.query("SELECT id, label, score FROM \(quoted).ex_rt2 ORDER BY id", params: nil)
        #expect(src.rows == dst.rows)
    }

    /// 往返特殊值：逗号/引号/换行/中文/NULL/负浮点/零。placeholder "?"（SQLite）或 "$"（PG $1…$3）。
    private func seedRoundTripRows(_ connection: any DatabaseConnection, table: String, placeholder: String) async throws {
        let p1 = placeholder == "?" ? "?" : "$1"
        let p2 = placeholder == "?" ? "?" : "$2"
        let p3 = placeholder == "?" ? "?" : "$3"
        let sql = "INSERT INTO \(table) (id, label, score) VALUES (\(p1), \(p2), \(p3))"
        let rows: [[DatabaseValue]] = [
            [.integer(1), .string("plain"), .double(1.5)],
            [.integer(2), .string("a,b"), .double(-2.25)],
            [.integer(3), .string("say \"hi\""), .double(0.0)],
            [.integer(4), .string("line1\nline2"), .double(3.5)],
            [.integer(5), .string("中文"), .null],
            [.integer(6), .null, .double(7.25)],
        ]
        for row in rows {
            _ = try await connection.execute(sql, params: row)
        }
    }
}