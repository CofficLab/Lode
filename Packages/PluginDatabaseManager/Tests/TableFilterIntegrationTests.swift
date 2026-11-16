import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-1 真实引擎验收：
// - 比较/文本/区间/集合/空值/正则各运算符在 SQLite/MySQL/PG 上筛选结果正确；
// - 数值/布尔列按类型绑定（PG 上文本绑定数值比较会失败，必须类型化）；
// - LIKE 通配符转义、大小写敏感开关、多条件 AND、raw WHERE、清空还原；
// - 注入尝试停留在参数里，表数据不受影响；
// - 筛选与排序/分页/行数统计联动正确。
//
// 网络引擎需本地 Docker：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT 后启用。
// SQLite 用临时文件库，无需 Docker，始终运行。`other` 为独立第二连接，用于建表与核验。

private func tfPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func tfInt(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    case .double(let d): return Int(d)
    default: return nil
    }
}

/// 取结果中 name 列的全部值（排序后便于断言）。MySQL TEXT 按 .data 返回，需 UTF-8 还原。
private func tfNames(_ result: QueryResult) -> [String] {
    guard let idx = result.columns.firstIndex(of: "name") else { return [] }
    return result.rows.compactMap { row in
        guard idx < row.count else { return nil }
        switch row[idx] {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        case .null: return nil
        default: return row[idx].description
        }
    }.sorted()
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct TableFilterIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func runFilterScenarios(vm: DatabaseViewModel, other: any DatabaseConnection, object: DatabaseObject) async throws {
        _ = try await other.execute("DROP TABLE IF EXISTS tf_people", params: nil)
        _ = try await other.execute(
            "CREATE TABLE tf_people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL, active BOOLEAN, note TEXT)",
            params: nil)
        let rows: [(Int, String, String, String, String, String)] = [
            (1, "ann", "25", "88.5", "true", "'hello world'"),
            (2, "bob", "32", "72.0", "false", "'Hello There'"),
            (3, "carol", "45", "91.5", "true", "NULL"),
            (4, "dave", "19", "60.0", "false", "'100%_done!'"),
            (5, "eve", "28", "77.25", "true", "''"),
            (6, "frank", "NULL", "55.0", "false", "'regex_target_42'"),
        ]
        for (id, name, age, score, active, note) in rows {
            _ = try await other.execute(
                "INSERT INTO tf_people (id, name, age, score, active, note) VALUES (\(id), '\(name)', \(age), \(score), \(active), \(note))",
                params: nil)
        }

        await vm.openObject(object)
        #expect(vm.queryResult?.rows.count == 6)
        // MySQL BOOLEAN 即 tinyint(1)：catalog 必须带修饰符，布尔操作数才能类型化绑定。
        if vm.selectedConfig?.type == .mysql {
            #expect(vm.selectedTableSchema?.columns.first { $0.name == "active" }?.dataType == "tinyint(1)")
        }

        func apply(_ filter: TableFilter) async {
            vm.tableFilter = filter
            await vm.applyFilter()
            await vm.refreshTableRowCount()
        }
        func cond(_ column: String, _ op: FilterOperator, _ operands: [String], caseSensitive: Bool = false) -> FilterCondition {
            FilterCondition(column: column, op: op, operands: operands, caseSensitive: caseSensitive)
        }

        // A. 数值相等：类型化绑定（PG 上文本绑定会报类型错误）。
        await apply(TableFilter(conditions: [cond("age", .equals, ["32"])]))
        #expect(vm.errorMessage == nil)
        #expect(tfNames(try #require(vm.queryResult)) == ["bob"])
        #expect(vm.tableRowCount == 1)
        #expect(vm.filterPreviewSQL?.hasPrefix("WHERE ") == true)

        // B/C. 文本包含：默认不区分大小写，开关后区分。
        await apply(TableFilter(conditions: [cond("note", .contains, ["hello"])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["ann", "bob"])
        await apply(TableFilter(conditions: [cond("note", .contains, ["Hello"], caseSensitive: true)]))
        #expect(tfNames(try #require(vm.queryResult)) == ["bob"])

        // D. 前缀匹配。
        await apply(TableFilter(conditions: [cond("note", .startsWith, ["h"])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["ann", "bob"])

        // E. 区间：两端都按列类型绑定。
        await apply(TableFilter(conditions: [cond("age", .between, ["25", "32"])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["ann", "bob", "eve"])
        #expect(vm.tableRowCount == 3)

        // F. 集合。
        await apply(TableFilter(conditions: [cond("name", .inList, ["ann", "eve"])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["ann", "eve"])

        // G. NULL 判定。
        await apply(TableFilter(conditions: [cond("age", .isNull, [])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["frank"])
        await apply(TableFilter(conditions: [cond("note", .isNull, [])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["carol"])

        // H. 空串判定（与 NULL 区分）。
        await apply(TableFilter(conditions: [cond("note", .isEmpty, [])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["eve"])
        await apply(TableFilter(conditions: [cond("note", .isNotEmpty, [])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["ann", "bob", "dave", "frank"])

        // I. 正则：三引擎各自方言（PG ~*、MySQL REGEXP_LIKE、SQLite REGEXP 自定义函数）。
        await apply(TableFilter(conditions: [cond("note", .regex, ["target_[0-9]+"])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["frank"])
        await apply(TableFilter(conditions: [cond("note", .regex, ["HELLO"])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["ann", "bob"])

        // J. LIKE 通配符按字面转义：% 和 _ 不当通配符。
        await apply(TableFilter(conditions: [cond("note", .contains, ["100%_"])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["dave"])

        // K. 多条件 AND + 布尔类型绑定。
        await apply(TableFilter(conditions: [cond("age", .greaterThan, ["20"]), cond("active", .equals, ["true"])]))
        #expect(tfNames(try #require(vm.queryResult)) == ["ann", "carol", "eve"])

        // L. raw WHERE 直通。
        await apply(TableFilter(useRawWhere: true, rawWhere: "age >= 28 AND age IS NOT NULL"))
        #expect(tfNames(try #require(vm.queryResult)) == ["bob", "carol", "eve"])
        #expect(vm.tableRowCount == 3)

        // M. 注入尝试停留在参数里：无论引擎如何处理，表数据完好。
        await apply(TableFilter(conditions: [cond("age", .equals, ["32; DROP TABLE tf_people"])]))
        #expect(tfInt(try await other.query("SELECT COUNT(*) FROM tf_people", params: nil)) == 6)

        // N. 清空筛选还原全量。
        await vm.clearFilter()
        await vm.refreshTableRowCount()
        #expect(vm.queryResult?.rows.count == 6)
        #expect(vm.tableRowCount == 6)
        #expect(vm.filterPreviewSQL == nil)

        // O. 筛选 × 排序 × 分页 × 行数联动。
        vm.tablePageSize = 2
        await apply(TableFilter(conditions: [cond("age", .isNotNull, [])]))
        #expect(vm.queryResult?.rows.count == 2)
        #expect(vm.tableRowCount == 5)
        await vm.toggleSort(column: "age")
        #expect(tfNames(try #require(vm.queryResult)) == ["ann", "dave"])
        await vm.nextPage()
        #expect(tfNames(try #require(vm.queryResult)) == ["bob", "eve"])
        await vm.nextPage()
        #expect(tfNames(try #require(vm.queryResult)) == ["carol"])
        await vm.setPageSize(100)

        _ = try await other.execute("DROP TABLE IF EXISTS tf_people", params: nil)
    }

    // MARK: - MySQL

    @Test(.enabled(if: tfPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlTableFiltering() async throws {
        let port = try #require(tfPort("LODE_TEST_MYSQL_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "tf", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        try await runFilterScenarios(vm: vm, other: other, object: DatabaseObject(kind: .table, name: "tf_people", database: "testdb"))
        await vm.disconnect()
    }

    // MARK: - PostgreSQL

    @Test(.enabled(if: tfPort("LODE_TEST_PG_PORT") != nil))
    func pgTableFiltering() async throws {
        let port = try #require(tfPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "tf", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        try await runFilterScenarios(vm: vm, other: other, object: DatabaseObject(kind: .table, name: "tf_people", schema: "public"))
        await vm.disconnect()
    }

    // MARK: - SQLite

    @Test func sqliteTableFiltering() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-tf-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "tf", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        try await runFilterScenarios(vm: vm, other: other, object: DatabaseObject(kind: .table, name: "tf_people"))
        await vm.disconnect()
    }
}