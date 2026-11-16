@testable import DatabaseManagerPlugin
import Foundation
import Testing

/// P1-5 批量执行策略：逐句继续（默认）与包裹事务失败回滚。
///
/// 用记录型假事务/假连接精确驱动 commit/rollback 路径与读语句归属，
/// 不依赖真实引擎（真实引擎验收见 BatchTransactionIntegrationTests）。
private actor BatchFakeTransaction: DatabaseTransaction {
    private(set) var committed = false
    private(set) var rolledBack = false
    private(set) var executed: [String] = []
    var failOn: String?

    func setFailOn(_ sql: String?) { failOn = sql }
    func commit() async throws { committed = true }
    func rollback() async throws { rolledBack = true }
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        executed.append(sql)
        if sql == failOn { throw DatabaseError.queryFailed("injected failure") }
        return 1
    }
}

private actor BatchFakeConnection: DatabaseConnection {
    let transaction = BatchFakeTransaction()
    private(set) var queries: [String] = []
    private(set) var executes: [String] = []
    private(set) var beginCount = 0
    var executeFailOn: String?
    var beginError: (any Error)?

    func setExecuteFailOn(_ sql: String?) { executeFailOn = sql }
    func setBeginError(_ error: (any Error)?) { beginError = error }

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        queries.append(sql)
        return QueryResult(columns: ["sql"], rows: [[.string(sql)]], rowsAffected: 0)
    }
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        executes.append(sql)
        if sql == executeFailOn { throw DatabaseError.queryFailed("injected failure") }
        return 1
    }
    func beginTransaction() async throws -> any DatabaseTransaction {
        beginCount += 1
        if let beginError { throw beginError }
        return transaction
    }
    func close() async {}
    func isAlive() async -> Bool { true }
    func cancel() async {}
}

private actor BatchFakeDriver: DatabaseDriver {
    nonisolated let type: DatabaseType
    let connection: BatchFakeConnection
    init(type: DatabaseType = .mysql, connection: BatchFakeConnection) {
        self.type = type
        self.connection = connection
    }
    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection { connection }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BatchExecutionPolicyTests {
    private func makeSUT(type: DatabaseType = .mysql) async -> (DatabaseViewModel, BatchFakeConnection) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let connection = BatchFakeConnection()
        await manager.register(driver: BatchFakeDriver(type: type, connection: connection))
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        await viewModel.connect(config: DatabaseConfig(name: "batch", type: type, host: "127.0.0.1", database: "testdb", username: "u"))
        return (viewModel, connection)
    }

    private func offset(of substring: String, in sql: String) -> Int {
        (sql as NSString).range(of: substring).location
    }

    // MARK: - 逐句继续（默认）

    @Test("默认策略：中间语句失败仍继续后续语句，不开事务")
    func continueOnErrorContinuesAfterFailure() async {
        let (viewModel, connection) = await makeSUT()
        viewModel.queryText = "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2); INSERT INTO t VALUES (3);"
        await connection.setExecuteFailOn("INSERT INTO t VALUES (2)")

        await viewModel.executeAllStatements()

        #expect(viewModel.batchPolicy == .continueOnError)
        #expect(viewModel.multiExecutions.count == 3)
        #expect(viewModel.multiExecutions[0].succeeded)
        #expect(viewModel.multiExecutions[1].succeeded == false)
        #expect(viewModel.multiExecutions[2].succeeded)
        #expect(viewModel.lastBatchRolledBack == false)
        #expect(await connection.beginCount == 0)
        #expect(await connection.executes.count == 3)
    }

    // MARK: - 包裹事务

    @Test("包裹事务：全部成功则提交，不回滚")
    func wrapInTransactionCommitsOnSuccess() async {
        let (viewModel, connection) = await makeSUT()
        viewModel.batchPolicy = .wrapInTransaction
        viewModel.queryText = "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);"

        await viewModel.executeAllStatements()

        #expect(await connection.transaction.committed)
        #expect(await connection.transaction.rolledBack == false)
        #expect(await connection.transaction.executed == ["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (2)"])
        #expect(viewModel.multiExecutions.count == 2)
        #expect(viewModel.lastBatchRolledBack == false)
    }

    @Test("包裹事务：中间语句失败即回滚并停止，后续语句不执行")
    func wrapInTransactionRollsBackOnFailure() async {
        let (viewModel, connection) = await makeSUT()
        viewModel.batchPolicy = .wrapInTransaction
        viewModel.queryText = "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2); INSERT INTO t VALUES (3);"
        await connection.transaction.setFailOn("INSERT INTO t VALUES (2)")

        await viewModel.executeAllStatements()

        #expect(await connection.transaction.rolledBack)
        #expect(await connection.transaction.committed == false)
        // 第三条不应被执行。
        #expect(await connection.transaction.executed == ["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (2)"])
        #expect(viewModel.multiExecutions.count == 2)
        #expect(viewModel.multiExecutions[1].succeeded == false)
        #expect(viewModel.lastBatchRolledBack)
    }

    @Test("包裹事务：读语句经同一连接 query 执行（处于事务内），写语句经事务 execute")
    func wrapInTransactionReadsUseConnectionQuery() async {
        let (viewModel, connection) = await makeSUT()
        viewModel.batchPolicy = .wrapInTransaction
        viewModel.queryText = "SELECT 1; INSERT INTO t VALUES (1);"

        await viewModel.executeAllStatements()

        #expect(await connection.queries.contains { $0.contains("SELECT 1") })
        #expect(await connection.transaction.executed == ["INSERT INTO t VALUES (1)"])
        #expect(await connection.transaction.committed)
        #expect(viewModel.multiExecutions.count == 2)
    }

    @Test("包裹事务：beginTransaction 失败时给出分类错误且不残留加载态")
    func wrapInTransactionBeginFailurePresentsError() async {
        let (viewModel, connection) = await makeSUT()
        viewModel.batchPolicy = .wrapInTransaction
        viewModel.queryText = "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);"
        await connection.setBeginError(DatabaseError.transactionFailed("cannot begin"))

        await viewModel.executeAllStatements()

        #expect(viewModel.isLoading == false)
        #expect(viewModel.errorMessage?.contains("cannot begin") == true)
        #expect(viewModel.multiExecutions.isEmpty)
    }

    @Test("单语句无论策略都走 executeQuery，不开事务")
    func singleStatementDelegatesWithoutTransaction() async {
        let (viewModel, connection) = await makeSUT()
        viewModel.batchPolicy = .wrapInTransaction
        viewModel.queryText = "SELECT 1;"

        await viewModel.executeAllStatements()

        #expect(await connection.beginCount == 0)
        #expect(viewModel.multiExecutions.isEmpty)
        #expect(viewModel.queryResult != nil)
    }

    // MARK: - 光标单句执行

    @Test("⌘↩ 只执行光标所在语句")
    func executeStatementAtCursorRunsOnlyCursorStatement() async {
        let (viewModel, connection) = await makeSUT()
        viewModel.queryText = "SELECT 1; SELECT 2;"
        viewModel.editorCursorLocation = offset(of: "SELECT 2", in: viewModel.queryText)

        await viewModel.executeStatementAtCursor()

        let last = await connection.queries.last
        #expect(last?.contains("SELECT 2") == true)
        #expect(last?.contains("SELECT 1") == false)
        #expect(viewModel.multiExecutions.isEmpty)
    }

    @Test("光标未知时退回执行整段文本（兼容降级编辑器）")
    func executeStatementAtCursorFallsBackWhenCursorUnknown() async {
        let (viewModel, connection) = await makeSUT()
        viewModel.queryText = "SELECT 1; SELECT 2;"
        viewModel.editorCursorLocation = NSNotFound

        await viewModel.executeStatementAtCursor()

        let last = await connection.queries.last
        #expect(last?.contains("SELECT 1") == true)
        #expect(last?.contains("SELECT 2") == true)
    }
}