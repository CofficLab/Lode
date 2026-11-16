import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-4 真实引擎验收：10 万行 CSV 流式导入 SQLite/MySQL/PG（COUNT + 抽样值核验），
// PG 保存点坏行隔离（事务中止语义）、MySQL JSON 导入、readOnly 拒绝、confirmWrites 取消/确认、PG 建新表路径。
// MySQL 经 switchDatabase 独立库（重连关闭旧连接，建库/清理/核验走驱动直连）；PG 经 switchSchema 独立 schema。

private func diPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func diInt(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func diDouble(_ value: DatabaseValue?) -> Double? {
    switch value {
    case .double(let d): return d
    case .integer(let i): return Double(i)
    case .string(let s): return Double(s)
    default: return nil
    }
}

private func diStrings(_ result: QueryResult) -> [String] {
    result.rows.compactMap { row in
        guard let first = row.first else { return nil }
        switch first {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        default: return first.description
        }
    }
}

/// 10 万行 CSV：score = i/4（二进制精确），便于跨引擎抽样核验。
private func diBigCSV(rows: Int) -> String {
    var lines = ["id,label,score"]
    lines.reserveCapacity(rows + 1)
    for i in 1...rows { lines.append("\(i),row\(i),\(Double(i) / 4)") }
    return lines.joined(separator: "\n") + "\n"
}

private func diMappings3() -> [ImportColumnMapping] {
    [
        ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer),
        ImportColumnMapping(sourceColumn: "label", targetColumn: "label", inferredType: .text),
        ImportColumnMapping(sourceColumn: "score", targetColumn: "score", inferredType: .double),
    ]
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct DataImportIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "lode-di-\(UUID().uuidString).\(ext)")
    }

    private func waitForConfirmation(_ vm: DatabaseViewModel) async -> Bool {
        for _ in 0..<20000 {
            if vm.writeConfirmation != nil { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: - 10 万行 CSV

    @Test func sqliteHundredThousandRowsCSV() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-di-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE imp_big (id INTEGER, label TEXT, score REAL)", params: nil)
        await vm.connect(config: DatabaseConfig(name: "di", type: .sqlite, database: path).withSafeMode(.off))
        #expect(vm.isConnected)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try diBigCSV(rows: 100_000).data(using: .utf8)!.write(to: url)
        await vm.loadImportPreview(url: url)
        #expect(vm.importError == nil)
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_big")), mappings: diMappings3())
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importCompleted)
        #expect(vm.importedRowCount == 100_000)
        #expect(vm.importBadRows.isEmpty)
        #expect(vm.importProgress == 1)

        let count = diInt(try await other.query("SELECT COUNT(*) FROM imp_big", params: nil))
        #expect(count == 100_000)
        let label = try await other.query("SELECT label FROM imp_big WHERE id=50000", params: nil).rows.first?.first
        #expect(label == .string("row50000"))
        let score = diDouble(try await other.query("SELECT score FROM imp_big WHERE id=100000", params: nil).rows.first?.first)
        #expect(score == 25000)
        await vm.disconnect()
    }

    @Test(.enabled(if: diPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlHundredThousandRowsCSV() async throws {
        let port = try #require(diPort("LODE_TEST_MYSQL_PORT"))
        let database = "di_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "di", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        // switchDatabase 会重连并关闭旧连接，建库/清理/核验走独立直连。
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { _ = try? await other.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil); await other.close(); await vm.disconnect() } }
        _ = try await other.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await other.execute("CREATE TABLE `\(database)`.imp_big (id INT, label VARCHAR(64), score DOUBLE) ENGINE=InnoDB", params: nil)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        await vm.switchDatabase(database)
        #expect(vm.activeDatabase == database)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try diBigCSV(rows: 100_000).data(using: .utf8)!.write(to: url)
        await vm.loadImportPreview(url: url)
        #expect(vm.importError == nil)
        let target = ImportTarget.existingTable(DatabaseObject(kind: .table, name: "imp_big", database: database))
        vm.startImport(target: target, mappings: diMappings3())
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importCompleted)
        #expect(vm.importedRowCount == 100_000)
        #expect(vm.importBadRows.isEmpty)

        let count = diInt(try await other.query("SELECT COUNT(*) FROM `\(database)`.imp_big", params: nil))
        #expect(count == 100_000)
        let label = try await other.query("SELECT label FROM `\(database)`.imp_big WHERE id=50000", params: nil).rows.first?.first
        #expect(label == .string("row50000"))
        let score = diDouble(try await other.query("SELECT score FROM `\(database)`.imp_big WHERE id=100000", params: nil).rows.first?.first)
        #expect(score == 25000)
    }

    @Test(.enabled(if: diPort("LODE_TEST_PG_PORT") != nil))
    func pgHundredThousandRowsCSV() async throws {
        let port = try #require(diPort("LODE_TEST_PG_PORT"))
        let schema = "di_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "di", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).imp_big (id INTEGER, label TEXT, score DOUBLE PRECISION)", params: nil)
        await vm.switchSchema(schema)
        #expect(vm.activeSchema == schema)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try diBigCSV(rows: 100_000).data(using: .utf8)!.write(to: url)
        await vm.loadImportPreview(url: url)
        #expect(vm.importError == nil)
        let target = ImportTarget.existingTable(DatabaseObject(kind: .table, name: "imp_big", schema: schema))
        vm.startImport(target: target, mappings: diMappings3())
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importCompleted)
        #expect(vm.importedRowCount == 100_000)
        #expect(vm.importBadRows.isEmpty)

        let count = diInt(try await conn.query("SELECT COUNT(*) FROM \(quoted).imp_big", params: nil))
        #expect(count == 100_000)
        let label = try await conn.query("SELECT label FROM \(quoted).imp_big WHERE id=50000", params: nil).rows.first?.first
        #expect(label == .string("row50000"))
        let score = diDouble(try await conn.query("SELECT score FROM \(quoted).imp_big WHERE id=100000", params: nil).rows.first?.first)
        #expect(score == 25000)
    }

    // MARK: - PG 坏行隔离（事务中止语义下的保存点）

    @Test(.enabled(if: diPort("LODE_TEST_PG_PORT") != nil))
    func pgBadRowIsolatedViaSavepoints() async throws {
        let port = try #require(diPort("LODE_TEST_PG_PORT"))
        let schema = "di_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "di", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).imp_u (id INTEGER, label TEXT UNIQUE)", params: nil)
        _ = try await conn.execute("INSERT INTO \(quoted).imp_u VALUES (99, 'dup')", params: nil)
        await vm.switchSchema(schema)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "id,label\n1,one\n2,dup\n3,three\n".data(using: .utf8)!.write(to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [
            ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "label", targetColumn: "label", inferredType: .text),
        ]
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_u", schema: schema)), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importCompleted)
        #expect(vm.importedRowCount == 2)
        #expect(vm.importBadRows.count == 1)
        #expect(vm.importBadRows[0].rowNumber == 2)
        let count = diInt(try await conn.query("SELECT COUNT(*) FROM \(quoted).imp_u", params: nil))
        #expect(count == 3)
    }

    // MARK: - MySQL JSON

    @Test(.enabled(if: diPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlJSONImportWithNull() async throws {
        let port = try #require(diPort("LODE_TEST_MYSQL_PORT"))
        let database = "di_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "di", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { _ = try? await other.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil); await other.close(); await vm.disconnect() } }
        _ = try await other.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await other.execute("CREATE TABLE `\(database)`.imp_j (id INT, label VARCHAR(64)) ENGINE=InnoDB", params: nil)
        await vm.connect(config: config)
        await vm.switchDatabase(database)

        let url = tempURL("json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "[{\"id\":1,\"label\":\"a\"},{\"id\":2,\"label\":null}]".data(using: .utf8)!.write(to: url)
        await vm.loadImportPreview(url: url)
        #expect(vm.importFormat == .json)
        let mappings = [
            ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer),
            ImportColumnMapping(sourceColumn: "label", targetColumn: "label", inferredType: .text),
        ]
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_j", database: database)), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importedRowCount == 2)
        let nullLabel = try await other.query("SELECT label FROM `\(database)`.imp_j WHERE id=2", params: nil).rows.first?.first
        #expect(nullLabel == .null)
    }

    // MARK: - 写闸门（真实引擎）

    @Test(.enabled(if: diPort("LODE_TEST_PG_PORT") != nil))
    func pgReadOnlyBlocksImport() async throws {
        let port = try #require(diPort("LODE_TEST_PG_PORT"))
        let schema = "di_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "di", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.readOnly)
        // readOnly 在驱动层同样拦截写语句，建 schema/核验/清理走独立直连。
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { _ = try? await other.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await other.close(); await vm.disconnect() } }
        _ = try await other.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await other.execute("CREATE TABLE \(quoted).imp_ro (id INTEGER)", params: nil)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        await vm.switchSchema(schema)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "id\n1\n2\n".data(using: .utf8)!.write(to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer)]
        vm.startImport(target: .existingTable(DatabaseObject(kind: .table, name: "imp_ro", schema: schema)), mappings: mappings)
        await vm.waitForImport()
        #expect(vm.importError != nil)
        #expect(vm.importCompleted == false)
        let count = diInt(try await other.query("SELECT COUNT(*) FROM \(quoted).imp_ro", params: nil))
        #expect(count == 0)
    }

    @Test(.enabled(if: diPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlConfirmWritesCancelAndApprove() async throws {
        let port = try #require(diPort("LODE_TEST_MYSQL_PORT"))
        let database = "di_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "di", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.confirmWrites)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { _ = try? await other.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil); await other.close(); await vm.disconnect() } }
        _ = try await other.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await other.execute("CREATE TABLE `\(database)`.imp_cf (id INT) ENGINE=InnoDB", params: nil)
        await vm.connect(config: config)
        await vm.switchDatabase(database)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "id\n1\n2\n3\n".data(using: .utf8)!.write(to: url)
        await vm.loadImportPreview(url: url)
        let mappings = [ImportColumnMapping(sourceColumn: "id", targetColumn: "id", inferredType: .integer)]
        let target = ImportTarget.existingTable(DatabaseObject(kind: .table, name: "imp_cf", database: database))

        vm.startImport(target: target, mappings: mappings)
        #expect(await waitForConfirmation(vm))
        #expect(vm.writeConfirmation?.kind == .batch)
        vm.resolveWriteConfirmation(false)
        await vm.waitForImport()
        #expect(vm.importCompleted == false)
        var count = diInt(try await other.query("SELECT COUNT(*) FROM `\(database)`.imp_cf", params: nil))
        #expect(count == 0)

        vm.startImport(target: target, mappings: mappings)
        #expect(await waitForConfirmation(vm))
        vm.resolveWriteConfirmation(true)
        await vm.waitForImport()
        #expect(vm.importError == nil)
        #expect(vm.importedRowCount == 3)
        count = diInt(try await other.query("SELECT COUNT(*) FROM `\(database)`.imp_cf", params: nil))
        #expect(count == 3)
    }

    // MARK: - PG 建新表路径

    @Test(.enabled(if: diPort("LODE_TEST_PG_PORT") != nil))
    func pgNewTableFromCSV() async throws {
        let port = try #require(diPort("LODE_TEST_PG_PORT"))
        let schema = "di_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "di", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        await vm.switchSchema(schema)

        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "id,score\n1,1.5\n2,2.5\n".data(using: .utf8)!.write(to: url)
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
        let columns = diStrings(try await conn.query("SELECT column_name FROM information_schema.columns WHERE table_schema='\(schema)' AND table_name='imp_new' ORDER BY ordinal_position", params: nil))
        #expect(columns == ["id", "score"])
        let types = diStrings(try await conn.query("SELECT data_type FROM information_schema.columns WHERE table_schema='\(schema)' AND table_name='imp_new' ORDER BY ordinal_position", params: nil))
        #expect(types == ["integer", "real"])
        let count = diInt(try await conn.query("SELECT COUNT(*) FROM \(quoted).imp_new", params: nil))
        #expect(count == 2)
    }
}