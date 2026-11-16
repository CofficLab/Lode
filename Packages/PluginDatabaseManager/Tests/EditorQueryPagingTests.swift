@testable import DatabaseManagerPlugin
import Foundation
import Testing

/// 模拟一张 `totalRows` 行的表：解析 SQL 里的 LIMIT/OFFSET 窗口返回对应行，
/// 并记录所有收到的 SQL。非测试查询（introspection 等）返回空结果。
private actor PagedFakeConnection: DatabaseConnection {
    private(set) var issuedSQL: [String] = []
    private let totalRows: Int
    private var blockNext = false
    private var blockedQueryStarted = false
    private var blockReleased = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(totalRows: Int) {
        self.totalRows = totalRows
    }

    func armBlock() {
        blockNext = true
    }

    func waitUntilBlocked() async {
        while !blockedQueryStarted {
            await Task.yield()
        }
    }

    func release() {
        blockReleased = true
        if let continuation = blockedContinuation {
            blockedContinuation = nil
            continuation.resume()
        }
    }

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        issuedSQL.append(sql)
        if blockNext {
            blockNext = false
            blockedQueryStarted = true
            await withCheckedContinuation { continuation in
                if blockReleased {
                    continuation.resume()
                } else {
                    blockedContinuation = continuation
                }
            }
        }
        guard sql.uppercased().contains("FROM T") else {
            return QueryResult(columns: [], rows: [], rowsAffected: 0)
        }
        let upper = sql.uppercased()
        var limit: Int?
        var offset = 0
        if let range = upper.range(of: "LIMIT ") {
            limit = Int(upper[range.upperBound...].prefix(while: { $0.isNumber }))
        }
        if let range = upper.range(of: "OFFSET ") {
            offset = Int(upper[range.upperBound...].prefix(while: { $0.isNumber })) ?? 0
        }
        let start = min(offset, totalRows)
        let end = limit.map { min(start + $0, totalRows) } ?? totalRows
        let rows = (start..<end).map { [DatabaseValue.integer($0)] }
        return QueryResult(columns: ["n"], rows: rows, rowsAffected: 0)
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        issuedSQL.append(sql)
        return 1
    }

    func beginTransaction() async throws -> any DatabaseTransaction {
        PagedTransaction()
    }

    func close() async {}
    func isAlive() async -> Bool { true }
    func cancel() async {}
}

private struct PagedTransaction: DatabaseTransaction {
    func commit() async throws {}
    func rollback() async throws {}
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
}

private actor PagedDriver: DatabaseDriver {
    nonisolated let type: DatabaseType = .postgresql
    private let connection: PagedFakeConnection

    init(connection: PagedFakeConnection) {
        self.connection = connection
    }

    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        connection
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EditorQueryPagingTests {
    private func makeSUT(totalRows: Int) async -> (DatabaseViewModel, PagedFakeConnection) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let connection = PagedFakeConnection(totalRows: totalRows)
        await manager.register(driver: PagedDriver(connection: connection))
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        let config = DatabaseConfig(name: "paging", type: .postgresql, database: "paging")
        await viewModel.connect(config: config)
        return (viewModel, connection)
    }

    @Test("无 LIMIT 的 SELECT 注入默认上限并允许加载更多")
    func injectsDefaultLimit() async {
        let (viewModel, connection) = await makeSUT(totalRows: 2500)
        viewModel.queryText = "SELECT * FROM t"
        await viewModel.executeQuery()

        #expect(viewModel.queryResult?.rows.count == 1000)
        #expect(viewModel.canLoadMoreEditorResults)
        #expect(viewModel.editorFetchedRows == 1000)
        let issued = await connection.issuedSQL
        #expect(issued.last?.contains("LIMIT 1000") == true)
    }

    @Test("加载更多按 OFFSET 窗口追加，取尽后关闭入口")
    func loadMoreAppendsWindows() async {
        let (viewModel, connection) = await makeSUT(totalRows: 2500)
        viewModel.queryText = "SELECT * FROM t"
        await viewModel.executeQuery()

        await viewModel.loadMoreEditorResults()
        #expect(viewModel.queryResult?.rows.count == 2000)
        #expect(viewModel.canLoadMoreEditorResults)

        await viewModel.loadMoreEditorResults()
        #expect(viewModel.queryResult?.rows.count == 2500)
        #expect(viewModel.editorHasMore == false)
        #expect(viewModel.canLoadMoreEditorResults == false)

        let issued = await connection.issuedSQL
        #expect(issued.contains { $0.contains("LIMIT 1000 OFFSET 1000") })
        #expect(issued.contains { $0.contains("LIMIT 1000 OFFSET 2000") })
        // 行内容连续无重复。
        let numbers = viewModel.queryResult?.rows.compactMap { row -> Int? in
            if case .integer(let value) = row.first { return value }
            return nil
        }
        #expect(numbers == Array(0..<2500))
    }

    @Test("用户自带 LIMIT 不被覆盖，也不提供加载更多")
    func respectsUserLimit() async {
        let (viewModel, _) = await makeSUT(totalRows: 2500)
        viewModel.queryText = "SELECT * FROM t LIMIT 5"
        await viewModel.executeQuery()

        #expect(viewModel.queryResult?.rows.count == 5)
        #expect(viewModel.canLoadMoreEditorResults == false)
        #expect(viewModel.editorBaseSQL == nil)
    }

    @Test("上限设为 0 时不注入")
    func zeroLimitDisablesInjection() async {
        let (viewModel, _) = await makeSUT(totalRows: 2500)
        viewModel.queryRowLimit = 0
        viewModel.queryText = "SELECT * FROM t"
        await viewModel.executeQuery()

        #expect(viewModel.queryResult?.rows.count == 2500)
        #expect(viewModel.canLoadMoreEditorResults == false)
    }

    @Test("写语句执行后清掉加载更多状态")
    func writeResetsPaging() async {
        let (viewModel, _) = await makeSUT(totalRows: 2500)
        viewModel.queryText = "SELECT * FROM t"
        await viewModel.executeQuery()
        #expect(viewModel.canLoadMoreEditorResults)

        viewModel.queryText = "UPDATE t SET n = 0"
        await viewModel.executeQuery()
        #expect(viewModel.canLoadMoreEditorResults == false)
        #expect(viewModel.editorBaseSQL == nil)
        #expect(viewModel.editorFetchedRows == 0)
    }

    @Test("迟到的旧查询结果不得覆盖新结果")
    func staleExecutionResultIsDiscarded() async {
        let (viewModel, connection) = await makeSUT(totalRows: 5000)
        await connection.armBlock()
        viewModel.queryText = "SELECT * FROM t"
        let first = Task { await viewModel.executeQuery() }
        await connection.waitUntilBlocked()

        viewModel.queryText = "SELECT * FROM t LIMIT 7"
        await viewModel.executeQuery()
        #expect(viewModel.queryResult?.rows.count == 7)

        await connection.release()
        await first.value
        #expect(viewModel.queryResult?.rows.count == 7)
        #expect(viewModel.isLoading == false)
    }

    @Test("多语句执行对每条读语句注入上限")
    func multiStatementInjectsPerStatement() async {
        let (viewModel, _) = await makeSUT(totalRows: 2500)
        viewModel.queryText = "SELECT * FROM t; SELECT * FROM t"
        await viewModel.executeAllStatements()

        #expect(viewModel.multiExecutions.count == 2)
        #expect(viewModel.multiExecutions[0].result?.rows.count == 1000)
        #expect(viewModel.multiExecutions[1].result?.rows.count == 1000)
        // 多结果模式不提供加载更多。
        #expect(viewModel.canLoadMoreEditorResults == false)
    }

    @Test("编辑器默认上限取自能力声明")
    func editorDefaultComesFromCapabilities() async {
        let viewModel = DatabaseViewModel(loadSavedConfigs: false)
        #expect(viewModel.queryRowLimit == DatabaseType.postgresql.capabilities.defaultQueryLimit)
        let (connected, _) = await makeSUT(totalRows: 10)
        #expect(connected.queryRowLimit == DatabaseType.postgresql.capabilities.defaultQueryLimit)
    }

    @Test("WITH 与 EXPLAIN 走读路径")
    func withAndExplainAreReads() {
        #expect(DatabaseViewModel.isReadStatement("WITH x AS (SELECT 1) SELECT * FROM x", type: .postgresql))
        #expect(DatabaseViewModel.isReadStatement("EXPLAIN SELECT * FROM t", type: .postgresql))
        #expect(DatabaseViewModel.isReadStatement("EXPLAIN ANALYZE SELECT * FROM t", type: .postgresql))
        #expect(DatabaseViewModel.isReadStatement("  with x as (select 1) select * from x", type: .sqlite))
        #expect(!DatabaseViewModel.isReadStatement("UPDATE t SET n = 1", type: .postgresql))
        #expect(!DatabaseViewModel.isReadStatement("INSERT INTO t VALUES (1)", type: .postgresql))
    }
}