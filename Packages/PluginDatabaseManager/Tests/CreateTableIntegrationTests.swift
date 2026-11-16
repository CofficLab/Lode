import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-3 真实引擎验收：建表表单管线（草稿→DDL→写闸门→事务执行→打开新表）。
// - SQLite（本地隔离临时库，始终运行）：列/主键/索引/外键真实落库，readOnly 拒绝，confirmWrites 取消/确认；
// - PostgreSQL / MySQL（Docker，按端口环境变量启用）：独立随机 schema/库，经 ViewModel 上下文建表并核验 catalog。
// 建表经 vm.createTable 走与改表一致的写闸门；父表与清理走驱动直连。

private func ctPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func ctInt(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func ctStrings(_ result: QueryResult) -> [String] {
    result.rows.compactMap { row in
        guard let first = row.first else { return nil }
        switch first {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        default: return first.description
        }
    }
}

private func ctDraft() -> NewTableDraft {
    NewTableDraft(
        name: "ct_orders",
        columns: [
            NewTableColumnDraft(name: "id", dataType: "INTEGER", isNullable: false),
            NewTableColumnDraft(name: "customer_id", dataType: "INTEGER", isNullable: true),
            NewTableColumnDraft(name: "label", dataType: "VARCHAR(64)", isNullable: false, defaultValue: "'x'"),
            NewTableColumnDraft(name: "amount", dataType: "REAL", isNullable: true),
        ],
        primaryKey: ["id"],
        indexes: [NewTableIndexDraft(name: "idx_ct_orders_label", columns: ["label"], isUnique: false)],
        foreignKeys: [NewTableForeignKeyDraft(columns: ["customer_id"], referencedTable: "ct_customers", referencedColumns: ["id"], onDelete: "CASCADE")]
    )
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct CreateTableIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func waitForConfirmation(_ vm: DatabaseViewModel) async -> Bool {
        for _ in 0..<5000 {
            if vm.writeConfirmation != nil { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: - SQLite（始终运行）

    @Test func sqliteCreateTablePersistsColumnsKeysAndOpens() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-ct-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ct_customers (id INTEGER PRIMARY KEY)", params: nil)
        await vm.connect(config: DatabaseConfig(name: "ct", type: .sqlite, database: path).withSafeMode(.off))
        #expect(vm.isConnected)

        await vm.createTable(ctDraft())
        #expect(vm.createTableError == nil)
        #expect(vm.openTableObject?.name == "ct_orders")

        let columnNames = try await other.query("PRAGMA table_info(ct_orders)", params: nil).rows.compactMap { $0.count > 1 ? $0[1].description : nil }
        #expect(columnNames.contains("id"))
        #expect(columnNames.contains("customer_id"))
        #expect(columnNames.contains("label"))
        #expect(columnNames.contains("amount"))
        let indexes = try await other.query("PRAGMA index_list(ct_orders)", params: nil).rows.compactMap { $0.count > 1 ? $0[1].description : nil }
        #expect(indexes.contains("idx_ct_orders_label"))
        let fks = try await other.query("PRAGMA foreign_key_list(ct_orders)", params: nil).rows
        #expect(fks.contains { $0.contains(.string("ct_customers")) })

        _ = try await other.execute("DROP TABLE IF EXISTS ct_orders", params: nil)
        _ = try await other.execute("DROP TABLE IF EXISTS ct_customers", params: nil)
        await vm.disconnect()
    }

    @Test func sqliteReadOnlyBlocksCreateTable() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-ct-ro-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        await vm.connect(config: DatabaseConfig(name: "ct", type: .sqlite, database: path).withSafeMode(.readOnly))
        await vm.createTable(ctDraft())
        #expect(vm.createTableError != nil)
        #expect(vm.isCreateTablePresented == false || vm.createTableError != nil)
        let tables = ctStrings(try await other.query("SELECT name FROM sqlite_master WHERE type='table' AND name='ct_orders'", params: nil))
        #expect(tables.isEmpty)
        await vm.disconnect()
    }

    @Test func sqliteConfirmCreateTableCancelAndApprove() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-ct-cf-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE ct_customers (id INTEGER PRIMARY KEY)", params: nil)
        await vm.connect(config: DatabaseConfig(name: "ct", type: .sqlite, database: path).withSafeMode(.confirmWrites))

        // 取消：表未建。
        let cancelTask = Task { await vm.createTable(ctDraft()) }
        #expect(await waitForConfirmation(vm))
        #expect(vm.writeConfirmation?.kind == .schemaChange)
        vm.resolveWriteConfirmation(false)
        await cancelTask.value
        var tables = ctStrings(try await other.query("SELECT name FROM sqlite_master WHERE type='table' AND name='ct_orders'", params: nil))
        #expect(tables.isEmpty)

        // 确认：表建成。
        let approveTask = Task { await vm.createTable(ctDraft()) }
        #expect(await waitForConfirmation(vm))
        vm.resolveWriteConfirmation(true)
        await approveTask.value
        tables = ctStrings(try await other.query("SELECT name FROM sqlite_master WHERE type='table' AND name='ct_orders'", params: nil))
        #expect(tables == ["ct_orders"])

        _ = try await other.execute("DROP TABLE IF EXISTS ct_orders", params: nil)
        _ = try await other.execute("DROP TABLE IF EXISTS ct_customers", params: nil)
        await vm.disconnect()
    }

    // MARK: - PostgreSQL（Docker）

    @Test(.enabled(if: ctPort("LODE_TEST_PG_PORT") != nil))
    func pgCreateTableInCustomSchema() async throws {
        let port = try #require(ctPort("LODE_TEST_PG_PORT"))
        let schema = "ct_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "ct", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).ct_customers (id INTEGER PRIMARY KEY)", params: nil)
        await vm.switchSchema(schema)
        #expect(vm.activeSchema == schema)

        await vm.createTable(ctDraft())
        #expect(vm.createTableError == nil)
        #expect(vm.openTableObject?.name == "ct_orders")

        let columns = ctStrings(try await conn.query("SELECT column_name FROM information_schema.columns WHERE table_schema='\(schema)' AND table_name='ct_orders' ORDER BY ordinal_position", params: nil))
        #expect(columns == ["id", "customer_id", "label", "amount"])
        let indexes = ctStrings(try await conn.query("SELECT indexname FROM pg_indexes WHERE schemaname='\(schema)' AND tablename='ct_orders'", params: nil))
        #expect(indexes.contains("idx_ct_orders_label"))
        let fkCount = ctInt(try await conn.query("SELECT COUNT(*) FROM information_schema.table_constraints WHERE table_schema='\(schema)' AND table_name='ct_orders' AND constraint_type='FOREIGN KEY'", params: nil))
        #expect(fkCount == 1)
    }

    // MARK: - MySQL（Docker）

    @Test(.enabled(if: ctPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlCreateTableInCustomDatabase() async throws {
        let port = try #require(ctPort("LODE_TEST_MYSQL_PORT"))
        let database = "ct_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "ct", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        // switchDatabase 会重连并关闭旧连接，建库/清理/核验走独立直连。
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { _ = try? await other.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil); await other.close(); await vm.disconnect() } }
        _ = try await other.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await other.execute("CREATE TABLE `\(database)`.ct_customers (id INT PRIMARY KEY) ENGINE=InnoDB", params: nil)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        await vm.switchDatabase(database)
        #expect(vm.activeDatabase == database)

        await vm.createTable(ctDraft())
        #expect(vm.createTableError == nil)
        #expect(vm.openTableObject?.name == "ct_orders")

        let columns = ctStrings(try await other.query("SELECT column_name FROM information_schema.columns WHERE table_schema='\(database)' AND table_name='ct_orders' ORDER BY ordinal_position", params: nil))
        #expect(columns == ["id", "customer_id", "label", "amount"])
        let indexes = ctStrings(try await other.query("SELECT DISTINCT index_name FROM information_schema.statistics WHERE table_schema='\(database)' AND table_name='ct_orders'", params: nil))
        #expect(indexes.contains("idx_ct_orders_label"))
        let fkCount = ctInt(try await other.query("SELECT COUNT(*) FROM information_schema.table_constraints WHERE table_schema='\(database)' AND table_name='ct_orders' AND constraint_type='FOREIGN KEY'", params: nil))
        #expect(fkCount == 1)
    }
}