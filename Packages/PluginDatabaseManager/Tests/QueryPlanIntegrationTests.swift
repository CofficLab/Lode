import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-2 真实引擎验收：EXPLAIN 计划解析 + 瓶颈定位 + PG ANALYZE 安全闸门。
// - SQLite（本地临时库，始终运行）：索引 SEARCH 提取索引名；子查询产生多节点计划树；
// - PostgreSQL / MySQL（Docker，按端口环境变量启用）：独立随机 schema/库，经 ViewModel
//   切换上下文后 explainCurrentQuery，节点关系/代价/行数正确；PG ANALYZE 回填实际时间；
// - PG ANALYZE 真实执行 DML 时走安全闸门：readOnly 拒绝（库不变）、confirmWrites 需确认
//   （取消→不执行、确认→真实删除并回填执行耗时）。
//
// 建表/清理走驱动直连或独立第二连接；只读 EXPLAIN 不修改数据库。

private func qpPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func qpInt(_ result: QueryResult) -> Int? {
    guard let first = result.rows.first?.first else { return nil }
    switch first {
    case .integer(let i): return i
    case .string(let s): return Int(s)
    case .double(let d): return Int(d)
    default: return nil
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct QueryPlanIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    /// 让出主 actor 直到写确认弹窗出现（ANALYZE 写流程挂起在续体上）。超时返回 false。
    private func waitForConfirmation(_ vm: DatabaseViewModel) async -> Bool {
        for _ in 0..<5000 {
            if vm.writeConfirmation != nil { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: - SQLite（始终运行）

    @Test func sqliteExplainExtractsIndexAndBuildsTree() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-qp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }
        _ = try await other.execute("CREATE TABLE qp_t (id INTEGER PRIMARY KEY, val INTEGER, name TEXT)", params: nil)
        _ = try await other.execute("CREATE INDEX idx_qp_val ON qp_t(val)", params: nil)
        _ = try await other.execute(
            "INSERT INTO qp_t (id, val, name) WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<100) SELECT n, n, 'x' FROM seq", params: nil)
        _ = try await other.execute("CREATE TABLE qp_u (id INTEGER PRIMARY KEY, val INTEGER)", params: nil)
        _ = try await other.execute("INSERT INTO qp_u (id, val) VALUES (1, 42), (2, 7)", params: nil)

        let config = DatabaseConfig(name: "qp", type: .sqlite, database: path).withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)

        // 索引等值查询：SEARCH 节点提取出索引名，瓶颈可定位。
        vm.queryText = "SELECT * FROM qp_t WHERE val = 42"
        await vm.explainCurrentQuery()
        #expect(vm.queryPlanError == nil)
        let searchPlan = try #require(vm.queryPlan)
        #expect(searchPlan.engine == .sqlite)
        #expect(searchPlan.roots.isEmpty == false)
        #expect(vm.isQueryPlanPresented)
        let searchNodes = searchPlan.allNodes()
        #expect(searchNodes.contains { $0.operation.contains("SEARCH") && $0.index == "idx_qp_val" })
        #expect(searchPlan.bottleneckNodeID != nil)

        // 子查询：计划至少两个节点（树/复合），不丢信息。
        vm.queryText = "SELECT * FROM qp_t WHERE val IN (SELECT val FROM qp_u)"
        await vm.explainCurrentQuery()
        let treePlan = try #require(vm.queryPlan)
        #expect(treePlan.allNodes().count >= 2)
        #expect(treePlan.bottleneckNodeID != nil)

        await vm.disconnect()
    }

    // MARK: - PostgreSQL（Docker）

    @Test(.enabled(if: qpPort("LODE_TEST_PG_PORT") != nil))
    func pgExplainAndAnalyzeBuildsPlan() async throws {
        let port = try #require(qpPort("LODE_TEST_PG_PORT"))
        let schema = "qp_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "qp", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).qp_t (id INTEGER PRIMARY KEY, val INTEGER)", params: nil)
        _ = try await conn.execute("INSERT INTO \(quoted).qp_t SELECT g, g FROM generate_series(1, 1000) g", params: nil)

        await vm.switchSchema(schema)
        #expect(vm.activeSchema == schema)

        // 普通 EXPLAIN：估算代价/行数，无实际时间。
        vm.queryText = "SELECT * FROM qp_t WHERE val = 42"
        await vm.explainCurrentQuery()
        #expect(vm.queryPlanError == nil)
        let plan = try #require(vm.queryPlan)
        #expect(plan.engine == .postgresql)
        #expect(plan.analyze == false)
        let root = try #require(plan.roots.first)
        #expect(root.relation == "qp_t")
        #expect(root.estimatedTotalCost != nil)
        #expect(root.estimatedRows != nil)
        #expect(root.actualTotalTimeMs == nil)
        #expect(plan.bottleneckNodeID != nil)

        // EXPLAIN ANALYZE：回填实际行数/时间/执行耗时。
        await vm.explainCurrentQuery(analyze: true)
        #expect(vm.queryPlanError == nil)
        let analyzed = try #require(vm.queryPlan)
        #expect(analyzed.analyze)
        #expect(analyzed.executionTimeMs != nil)
        let analyzedRoot = try #require(analyzed.roots.first)
        #expect(analyzedRoot.actualTotalTimeMs != nil)
        #expect(analyzedRoot.actualRows != nil)
        #expect(analyzed.bottleneckNodeID != nil)
    }

    // MARK: - MySQL（Docker）

    @Test(.enabled(if: qpPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlExplainBuildsPlan() async throws {
        let port = try #require(qpPort("LODE_TEST_MYSQL_PORT"))
        let database = "qp_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "qp", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let seed = try #require(await manager.getConnection(for: config.id))
        _ = try await seed.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await seed.execute("CREATE TABLE `\(database)`.qp_t (id INT PRIMARY KEY, val INT, KEY idx_val (val)) ENGINE=InnoDB", params: nil)
        let values = (1...20).map { "(\($0), \($0))" }.joined(separator: ", ")
        _ = try await seed.execute("INSERT INTO `\(database)`.qp_t (id, val) VALUES \(values)", params: nil)
        defer { Task {
            if let live = await manager.getConnection(for: config.id) {
                _ = try? await live.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil)
            }
            await vm.disconnect()
        } }

        await vm.switchDatabase(database)
        #expect(vm.activeDatabase == database)
        vm.queryText = "SELECT * FROM qp_t WHERE val = 42"
        await vm.explainCurrentQuery()
        #expect(vm.queryPlanError == nil)
        let plan = try #require(vm.queryPlan)
        #expect(plan.engine == .mysql)
        #expect(plan.roots.isEmpty == false)
        let nodes = plan.allNodes()
        #expect(nodes.contains { $0.relation == "qp_t" })
        #expect(nodes.contains { $0.estimatedRows != nil })
        #expect(plan.bottleneckNodeID != nil)
    }

    // MARK: - PG ANALYZE 安全闸门（Docker）

    @Test(.enabled(if: qpPort("LODE_TEST_PG_PORT") != nil))
    func pgAnalyzeDeleteReadOnlyBlocked() async throws {
        let port = try #require(qpPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS qp_ro", params: nil)
        _ = try await other.execute("CREATE TABLE qp_ro (id INTEGER PRIMARY KEY, val INTEGER)", params: nil)
        _ = try await other.execute("INSERT INTO qp_ro SELECT g, g FROM generate_series(1, 100) g", params: nil)

        let config = DatabaseConfig(name: "qp", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.readOnly)
        await vm.connect(config: config)
        #expect(vm.isConnected)

        // ANALYZE DELETE 是真实写：readOnly 拒绝，计划不展示，库不变。
        vm.queryText = "DELETE FROM qp_ro WHERE val <= 10"
        await vm.explainCurrentQuery(analyze: true)
        #expect(vm.queryPlan == nil)
        #expect(vm.isQueryPlanPresented == false)
        #expect(vm.classifiedError?.category == .permissionDenied)
        #expect(qpInt(try await other.query("SELECT COUNT(*) FROM qp_ro", params: nil)) == 100)

        _ = try await other.execute("DROP TABLE IF EXISTS qp_ro", params: nil)
        await vm.disconnect()
    }

    @Test(.enabled(if: qpPort("LODE_TEST_PG_PORT") != nil))
    func pgAnalyzeDeleteConfirmWritesCancelAndApprove() async throws {
        let port = try #require(qpPort("LODE_TEST_PG_PORT"))
        let (vm, _) = await makeSUT()
        let other = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await other.close() } }
        _ = try await other.execute("DROP TABLE IF EXISTS qp_cf", params: nil)
        _ = try await other.execute("CREATE TABLE qp_cf (id INTEGER PRIMARY KEY, val INTEGER)", params: nil)
        _ = try await other.execute("INSERT INTO qp_cf SELECT g, g FROM generate_series(1, 100) g", params: nil)

        let config = DatabaseConfig(name: "qp", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.confirmWrites)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        vm.queryText = "DELETE FROM qp_cf WHERE val <= 10"

        // 取消：ANALYZE 不执行，库不变，无计划。
        let cancelTask = Task { await vm.explainCurrentQuery(analyze: true) }
        #expect(await waitForConfirmation(vm))
        #expect(vm.writeConfirmation?.kind == .query)
        #expect(qpInt(try await other.query("SELECT COUNT(*) FROM qp_cf", params: nil)) == 100)
        vm.resolveWriteConfirmation(false)
        await cancelTask.value
        #expect(vm.writeConfirmation == nil)
        #expect(vm.queryPlan == nil)
        #expect(qpInt(try await other.query("SELECT COUNT(*) FROM qp_cf", params: nil)) == 100)

        // 确认：ANALYZE 真实执行 DELETE（行数减少），并回填执行耗时。
        let approveTask = Task { await vm.explainCurrentQuery(analyze: true) }
        #expect(await waitForConfirmation(vm))
        vm.resolveWriteConfirmation(true)
        await approveTask.value
        #expect(qpInt(try await other.query("SELECT COUNT(*) FROM qp_cf", params: nil)) == 90)
        let plan = try #require(vm.queryPlan)
        #expect(plan.analyze)
        #expect(plan.executionTimeMs != nil)

        _ = try await other.execute("DROP TABLE IF EXISTS qp_cf", params: nil)
        await vm.disconnect()
    }
}