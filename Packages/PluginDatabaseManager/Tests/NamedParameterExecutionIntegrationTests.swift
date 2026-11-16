import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-4 真实引擎验收：命名参数 `:name` 经面板绑定后，按引擎预处理执行。
// 网络引擎需本地 Docker：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT 后启用。
// SQLite 用临时文件库，无需 Docker，始终运行。
//
// 覆盖：类型化 INSERT、重复参数 SELECT、NULL 绑定、缺值拦截、非法类型拦截、批量参数化。

private func npPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func npIntValue(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    default: return nil
    }
}

/// 文本内容比较：MySQL 把 TEXT 列按 blob 线上类型回成 .data，PG/SQLite 回成 .string，
/// 参数化执行验收只关心内容正确，不依赖各驱动的类型映射差异。
private func npText(_ value: DatabaseValue?) -> String? {
    switch value {
    case .string(let s): return s
    case .data(let d): return String(data: d, encoding: .utf8)
    default: return nil
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct NamedParameterExecutionIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func bind(_ viewModel: DatabaseViewModel, _ name: String, kind: QueryParameterBinding.Kind, text: String = "", isNull: Bool = false) {
        viewModel.parameterBindings[name] = QueryParameterBinding(kind: kind, text: text, isNull: isNull)
    }

    /// 在给定连接上跑命名参数全流程，断言引擎侧真实落库与拦截行为。
    private func runParameterScenario(connection: any DatabaseConnection, viewModel: DatabaseViewModel) async throws {
        _ = try await connection.execute("DROP TABLE IF EXISTS np_t", params: nil)
        _ = try await connection.execute("CREATE TABLE np_t (id INTEGER, name TEXT, amount REAL)", params: nil)

        // 1) 类型化参数 INSERT：整数 / 文本 / 实数分别绑定。
        viewModel.queryText = "INSERT INTO np_t (id, name, amount) VALUES (:id, :name, :amount)"
        bind(viewModel, "id", kind: .integer, text: "1")
        bind(viewModel, "name", kind: .text, text: "alice")
        bind(viewModel, "amount", kind: .real, text: "9.5")
        await viewModel.executeQuery()
        #expect(viewModel.errorMessage == nil)
        let inserted = npIntValue(try await connection.query("SELECT COUNT(*) FROM np_t WHERE id = 1 AND name = 'alice' AND amount = 9.5", params: nil))
        #expect(inserted == 1)

        // 2) 重复参数 SELECT：同一 :id 出现两次，按出现顺序绑定同值。
        viewModel.queryText = "SELECT name FROM np_t WHERE id = :id OR id = :id"
        bind(viewModel, "id", kind: .integer, text: "1")
        await viewModel.executeQuery()
        #expect(npText(viewModel.queryResult?.rows.first?.first) == "alice")

        // 3) NULL 绑定：name 置 NULL，引擎侧确为 NULL。
        viewModel.queryText = "INSERT INTO np_t (id, name, amount) VALUES (:id, :name, :amount)"
        bind(viewModel, "id", kind: .integer, text: "2")
        bind(viewModel, "name", kind: .text, isNull: true)
        bind(viewModel, "amount", kind: .real, text: "0")
        await viewModel.executeQuery()
        #expect(viewModel.errorMessage == nil)
        let nullCount = npIntValue(try await connection.query("SELECT COUNT(*) FROM np_t WHERE id = 2 AND name IS NULL", params: nil))
        #expect(nullCount == 1)

        // 4) 缺值拦截：name 未提供 → 执行前报错，不落库。
        let beforeMissing = npIntValue(try await connection.query("SELECT COUNT(*) FROM np_t", params: nil))
        viewModel.queryText = "INSERT INTO np_t (id, name, amount) VALUES (:id, :name, :amount)"
        bind(viewModel, "id", kind: .integer, text: "3")
        viewModel.parameterBindings["name"] = QueryParameterBinding() // 空文本 = 缺值
        bind(viewModel, "amount", kind: .real, text: "1")
        await viewModel.executeQuery()
        // 错误文案随系统语言本地化，断言用稳定的参数名后缀（:name）而非英文前缀。
        #expect(viewModel.errorMessage?.contains(":name") == true)
        let afterMissing = npIntValue(try await connection.query("SELECT COUNT(*) FROM np_t", params: nil))
        #expect(afterMissing == beforeMissing)

        // 5) 非法类型拦截：integer 绑定非数字 → 执行前报错，不落库。
        viewModel.queryText = "INSERT INTO np_t (id, name, amount) VALUES (:id, :name, :amount)"
        bind(viewModel, "id", kind: .integer, text: "notanint")
        bind(viewModel, "name", kind: .text, text: "bob")
        bind(viewModel, "amount", kind: .real, text: "1")
        await viewModel.executeQuery()
        #expect(viewModel.errorMessage?.contains(":id") == true)
        let afterInvalid = npIntValue(try await connection.query("SELECT COUNT(*) FROM np_t", params: nil))
        #expect(afterInvalid == beforeMissing)

        // 6) 批量参数化：两条 INSERT 各自命名参数，逐句继续全部成功。
        viewModel.queryText = "INSERT INTO np_t (id, name) VALUES (:idA, :nameA); INSERT INTO np_t (id, name) VALUES (:idB, :nameB)"
        viewModel.batchPolicy = .continueOnError
        bind(viewModel, "idA", kind: .integer, text: "10")
        bind(viewModel, "nameA", kind: .text, text: "carol")
        bind(viewModel, "idB", kind: .integer, text: "11")
        bind(viewModel, "nameB", kind: .text, text: "dave")
        await viewModel.executeAllStatements()
        #expect(viewModel.multiExecutions.count == 2)
        #expect(viewModel.multiExecutions.allSatisfy { $0.succeeded })
        let batchCount = npIntValue(try await connection.query("SELECT COUNT(*) FROM np_t WHERE id IN (10, 11)", params: nil))
        #expect(batchCount == 2)

        _ = try await connection.execute("DROP TABLE IF EXISTS np_t", params: nil)
    }

    @Test(.enabled(if: npPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlNamedParameters() async throws {
        let port = try #require(npPort("LODE_TEST_MYSQL_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "np", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runParameterScenario(connection: connection, viewModel: viewModel)
        await viewModel.disconnect()
    }

    @Test(.enabled(if: npPort("LODE_TEST_PG_PORT") != nil))
    func pgNamedParameters() async throws {
        let port = try #require(npPort("LODE_TEST_PG_PORT"))
        let (viewModel, manager) = await makeSUT()
        let config = DatabaseConfig(name: "np", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test")
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runParameterScenario(connection: connection, viewModel: viewModel)
        await viewModel.disconnect()
    }

    @Test func sqliteNamedParameters() async throws {
        let (viewModel, manager) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-np-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "np", type: .sqlite, database: path)
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected)
        let connection = try #require(await manager.getConnection(for: config.id))
        try await runParameterScenario(connection: connection, viewModel: viewModel)
        await viewModel.disconnect()
    }
}