import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-2 真实引擎验收：
// - MySQL enum / PG enum 列经类型化解析 → 变更队列 → 提交 → 重读往返正确；
// - PG 数组列按文本字面量编辑往返；JSON/JSONB 编辑校验后往返（语义相等）；
// - 日期/日期时间/时间列文本往返（SQLite/MySQL/PG）；
// - 布尔开关解析为 bool 写入（MySQL tinyint(1) → 0/1）；
// - Set Default：MySQL/PG 生成 DEFAULT 关键字；SQLite 先解析默认表达式再写具体值
//   （含 CURRENT_TIMESTAMP）；
// - NULL 与空串明确区分。
//
// 网络引擎需本地 Docker：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT 后启用。
// SQLite 用临时文件库，无需 Docker，始终运行。`other` 为独立第二连接，用于建表与核验。

private func tcPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

/// 文本解码：MySQL 的 TEXT/JSON/DATETIME 等可能按 .data 返回，需 UTF-8 还原。
private func tcText(_ value: DatabaseValue) -> String? {
    switch value {
    case .string(let s): return s
    case .data(let d): return String(data: d, encoding: .utf8)
    default: return nil
    }
}

private func tcInt(_ value: DatabaseValue) -> Int? {
    switch value {
    case .integer(let i): return i
    case .bool(let b): return b ? 1 : 0
    case .string(let s): return Int(s)
    case .data(let d): return String(data: d, encoding: .utf8).flatMap(Int.init)
    default: return nil
    }
}

private func tcJSONEqual(_ a: String?, _ b: String) -> Bool {
    guard let a,
          let da = a.data(using: .utf8),
          let db = b.data(using: .utf8),
          let ja = try? JSONSerialization.jsonObject(with: da, options: [.allowFragments]),
          let jb = try? JSONSerialization.jsonObject(with: db, options: [.allowFragments]) else { return false }
    return (ja as? NSObject) == (jb as? NSObject)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct TypedCellEditingIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    /// 模拟编辑器提交路径：类型感知解析后暂存，保存，返回重读到的该行。
    private func editAndSave(
        vm: DatabaseViewModel,
        column: String,
        text: String
    ) async throws {
        let result = try #require(vm.queryResult)
        let row = result.rows[0]
        let columns = result.columns
        let original = result.columns.firstIndex(of: column).flatMap { idx in
            idx < row.count ? row[idx] : nil
        }
        let value = parseEditedCellValue(text, columnType: vm.changeManager?.columnType(of: column), original: original)
        vm.stageCellChange(column: column, newValue: value, rowValues: row, columns: columns)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        #expect(vm.changeManager?.hasChanges == false)
    }

    private func savedRow(_ other: any DatabaseConnection, table: String, column: String) async throws -> DatabaseValue {
        let result = try await other.query("SELECT \(column) FROM \(table) WHERE id = 1;", params: nil)
        return try #require(result.rows.first?.first)
    }

    // MARK: - MySQL

    @Test(.enabled(if: tcPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlTypedEditing() async throws {
        let port = try #require(tcPort("LODE_TEST_MYSQL_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "tc", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await other.close() } }

        _ = try await other.execute("DROP TABLE IF EXISTS tc_edit", params: nil)
        _ = try await other.execute(
            """
            CREATE TABLE tc_edit (
              id INT PRIMARY KEY,
              color ENUM('red','green','blue') NOT NULL DEFAULT 'red',
              payload JSON,
              created DATETIME,
              flag BOOLEAN DEFAULT FALSE,
              qty INT DEFAULT 7,
              note VARCHAR(64) DEFAULT 'hello'
            )
            """, params: nil)
        _ = try await other.execute(
            "INSERT INTO tc_edit (id, color, payload, created, flag, qty, note) VALUES (1, 'red', '{\"a\":1}', '2024-01-01 08:00:00', 1, 3, 'x')",
            params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "tc_edit", database: "testdb"))
        #expect(vm.queryResult?.rows.count == 1)
        let schema = try #require(vm.selectedTableSchema)
        let colorColumn = try #require(schema.columns.first { $0.name == "color" })
        #expect(colorColumn.enumValues == ["red", "green", "blue"])
        #expect(cellEditorKind(for: colorColumn.dataType, enumValues: colorColumn.enumValues) == .enumeration(["red", "green", "blue"]))
        #expect(schema.columns.first { $0.name == "flag" }?.dataType == "tinyint(1)")

        // enum 往返
        try await editAndSave(vm: vm, column: "color", text: "green")
        #expect(tcText(try await savedRow(other, table: "tc_edit", column: "color")) == "green")

        // JSON 往返（MySQL 会规范化空白，按语义比较）
        try await editAndSave(vm: vm, column: "payload", text: "{\"b\":[2,3]}")
        #expect(tcJSONEqual(tcText(try await savedRow(other, table: "tc_edit", column: "payload")), "{\"b\":[2,3]}"))

        // 布尔开关：false → 0
        try await editAndSave(vm: vm, column: "flag", text: "false")
        #expect(tcInt(try await savedRow(other, table: "tc_edit", column: "flag")) == 0)

        // 日期时间往返
        try await editAndSave(vm: vm, column: "created", text: "2024-03-05 14:30:09")
        let created = tcText(try await savedRow(other, table: "tc_edit", column: "created"))
        #expect(parseCellDate(created ?? "", kind: .dateTime) == parseCellDate("2024-03-05 14:30:09", kind: .dateTime))

        // Set Default：DEFAULT 关键字提交，恢复列默认值
        let row = try #require(vm.queryResult?.rows.first)
        let columns = try #require(vm.queryResult?.columns)
        await vm.stageCellDefault(column: "qty", rowValues: row, columns: columns)
        #expect(vm.changeManager?.isCellDefault(column: "qty", rowValues: row, columns: columns) == true)
        #expect(vm.pendingChangeSQL.contains { $0.contains("`qty` = DEFAULT") })
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        #expect(tcInt(try await savedRow(other, table: "tc_edit", column: "qty")) == 7)

        // 空串与 NULL 明确区分
        try await editAndSave(vm: vm, column: "note", text: "")
        #expect(tcText(try await savedRow(other, table: "tc_edit", column: "note")) == "")
        let row2 = try #require(vm.queryResult?.rows.first)
        vm.stageCellChange(column: "note", newValue: .null, rowValues: row2, columns: columns)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        #expect(try await savedRow(other, table: "tc_edit", column: "note") == .null)

        _ = try await other.execute("DROP TABLE IF EXISTS tc_edit", params: nil)
        await vm.disconnect()
    }

    // MARK: - PostgreSQL

    @Test(.enabled(if: tcPort("LODE_TEST_PG_PORT") != nil))
    func pgTypedEditing() async throws {
        let port = try #require(tcPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let config = DatabaseConfig(name: "tc", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }

        _ = try await other.execute("DROP TABLE IF EXISTS tc_edit", params: nil)
        _ = try await other.execute("DROP TYPE IF EXISTS tc_mood", params: nil)
        _ = try await other.execute("CREATE TYPE tc_mood AS ENUM ('happy','sad','ok')", params: nil)
        _ = try await other.execute(
            """
            CREATE TABLE tc_edit (
              id INT PRIMARY KEY,
              mood tc_mood DEFAULT 'ok',
              tags INTEGER[],
              payload JSONB,
              created TIMESTAMP,
              qty INT DEFAULT 7
            )
            """, params: nil)
        _ = try await other.execute(
            "INSERT INTO tc_edit (id, mood, tags, payload, created, qty) VALUES (1, 'happy', '{1,2}', '{\"a\":1}', '2024-01-01 08:00:00', 3)",
            params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "tc_edit", schema: "public"))
        #expect(vm.queryResult?.rows.count == 1)
        let schema = try #require(vm.selectedTableSchema)
        let moodColumn = try #require(schema.columns.first { $0.name == "mood" })
        #expect(moodColumn.dataType == "USER-DEFINED")
        #expect(moodColumn.enumValues == ["happy", "sad", "ok"])
        let tagsColumn = try #require(schema.columns.first { $0.name == "tags" })
        #expect(cellEditorKind(for: tagsColumn.dataType) == .text)

        // enum 往返
        try await editAndSave(vm: vm, column: "mood", text: "sad")
        #expect(tcText(try await savedRow(other, table: "tc_edit", column: "mood")) == "sad")

        // 数组按文本字面量往返
        try await editAndSave(vm: vm, column: "tags", text: "{4,5,6}")
        #expect(tcText(try await savedRow(other, table: "tc_edit", column: "tags")) == "{4,5,6}")

        // JSONB 往返（规范化后按语义比较）
        try await editAndSave(vm: vm, column: "payload", text: "{\"b\":2}")
        #expect(tcJSONEqual(tcText(try await savedRow(other, table: "tc_edit", column: "payload")), "{\"b\":2}"))

        // timestamp 往返
        try await editAndSave(vm: vm, column: "created", text: "2024-03-05 14:30:09")
        let created = tcText(try await savedRow(other, table: "tc_edit", column: "created"))
        #expect(parseCellDate(created ?? "", kind: .dateTime) == parseCellDate("2024-03-05 14:30:09", kind: .dateTime))

        // Set Default：DEFAULT 关键字
        let row = try #require(vm.queryResult?.rows.first)
        let columns = try #require(vm.queryResult?.columns)
        await vm.stageCellDefault(column: "qty", rowValues: row, columns: columns)
        #expect(vm.pendingChangeSQL.contains { $0.contains("\"qty\" = DEFAULT") })
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        #expect(tcInt(try await savedRow(other, table: "tc_edit", column: "qty")) == 7)

        _ = try await other.execute("DROP TABLE IF EXISTS tc_edit", params: nil)
        _ = try await other.execute("DROP TYPE IF EXISTS tc_mood", params: nil)
        await vm.disconnect()
    }

    // MARK: - SQLite

    @Test func sqliteTypedEditing() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-tc-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "tc", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }

        _ = try await other.execute(
            """
            CREATE TABLE tc_edit (
              id INTEGER PRIMARY KEY,
              d DATE,
              dt DATETIME,
              t TIME,
              flag BOOLEAN,
              qty INTEGER DEFAULT 7,
              note TEXT DEFAULT 'hello',
              ts DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """, params: nil)
        _ = try await other.execute(
            "INSERT INTO tc_edit (id, d, dt, t, flag, qty, note) VALUES (1, '2024-01-01', '2024-01-01 08:00:00', '08:15:42', 1, 3, 'x')",
            params: nil)

        await vm.openObject(DatabaseObject(kind: .table, name: "tc_edit"))
        #expect(vm.queryResult?.rows.count == 1)
        let schema = try #require(vm.selectedTableSchema)
        #expect(cellEditorKind(for: schema.columns.first { $0.name == "d" }?.dataType ?? "") == .date)
        #expect(cellEditorKind(for: schema.columns.first { $0.name == "dt" }?.dataType ?? "") == .dateTime)
        #expect(cellEditorKind(for: schema.columns.first { $0.name == "t" }?.dataType ?? "") == .time)

        // 日期/日期时间/时间往返（编辑器格式化文本 → 提交 → 重读一致）
        let dateText = formatCellDate(try #require(parseCellDate("2024-03-05", kind: .date)), kind: .date)
        try await editAndSave(vm: vm, column: "d", text: dateText ?? "")
        #expect(tcText(try await savedRow(other, table: "tc_edit", column: "d")) == "2024-03-05")

        try await editAndSave(vm: vm, column: "dt", text: "2024-03-05 14:30:09")
        #expect(tcText(try await savedRow(other, table: "tc_edit", column: "dt")) == "2024-03-05 14:30:09")

        try await editAndSave(vm: vm, column: "t", text: "09:45:00")
        #expect(tcText(try await savedRow(other, table: "tc_edit", column: "t")) == "09:45:00")

        // 布尔：false → 0
        try await editAndSave(vm: vm, column: "flag", text: "false")
        #expect(tcInt(try await savedRow(other, table: "tc_edit", column: "flag")) == 0)

        // Set Default：SQLite 不支持 UPDATE … DEFAULT，先解析默认表达式为具体值。
        var row = try #require(vm.queryResult?.rows.first)
        let columns = try #require(vm.queryResult?.columns)
        await vm.stageCellDefault(column: "qty", rowValues: row, columns: columns)
        #expect(vm.pendingChangeSQL.contains { $0.contains("\"qty\" = 7") })
        #expect(!vm.pendingChangeSQL.contains { $0.contains("DEFAULT") && $0.hasPrefix("UPDATE") })
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        #expect(tcInt(try await savedRow(other, table: "tc_edit", column: "qty")) == 7)

        // 文本默认值 'hello'
        row = try #require(vm.queryResult?.rows.first)
        await vm.stageCellDefault(column: "note", rowValues: row, columns: columns)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        #expect(tcText(try await savedRow(other, table: "tc_edit", column: "note")) == "hello")

        // CURRENT_TIMESTAMP 默认值：解析为当前时间文本并可被日期时间格式解析
        row = try #require(vm.queryResult?.rows.first)
        await vm.stageCellDefault(column: "ts", rowValues: row, columns: columns)
        await vm.saveChanges()
        #expect(vm.errorMessage == nil)
        let ts = tcText(try await savedRow(other, table: "tc_edit", column: "ts"))
        #expect(parseCellDate(ts ?? "", kind: .dateTime) != nil)

        _ = try await other.execute("DROP TABLE IF EXISTS tc_edit", params: nil)
        await vm.disconnect()
    }
}