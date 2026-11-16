@testable import DatabaseManagerPlugin
import Foundation
import Testing

/// 错误恢复闭环：分类落到 ViewModel、重试重连/重跑、编辑连接入口、清空同步。
private actor ErrorFakeConnection: DatabaseConnection {
    var queryError: (any Error)?
    var failPattern: String?

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        if let queryError { throw queryError }
        if let failPattern, sql.contains(failPattern) {
            throw DatabaseError.queryFailed("no such table: \(failPattern)")
        }
        return QueryResult(columns: ["n"], rows: [[.integer(1)]], rowsAffected: 0)
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 1 }
    func beginTransaction() async throws -> any DatabaseTransaction { ErrorFakeTransaction() }
    func close() async {}
    func isAlive() async -> Bool { true }
    func cancel() async {}
}

private struct ErrorFakeTransaction: DatabaseTransaction {
    func commit() async throws {}
    func rollback() async throws {}
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
}

private actor ErrorFakeDriver: DatabaseDriver {
    nonisolated let type: DatabaseType = .mysql
    var connectError: (any Error)?
    private(set) var connectAttempts = 0
    let connection: ErrorFakeConnection

    init(connection: ErrorFakeConnection) {
        self.connection = connection
    }

    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        connectAttempts += 1
        if let connectError { throw connectError }
        return connection
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DatabaseErrorRecoveryTests {
    private func makeSUT() async -> (DatabaseViewModel, ErrorFakeDriver, ErrorFakeConnection) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let connection = ErrorFakeConnection()
        let driver = ErrorFakeDriver(connection: connection)
        await manager.register(driver: driver)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, driver, connection)
    }

    private func makeConfig() -> DatabaseConfig {
        DatabaseConfig(name: "err", type: .mysql, host: "127.0.0.1", database: "testdb", username: "u")
    }

    @Test func connectFailureClassifiesAndOffersEdit() async {
        let (viewModel, driver, _) = await makeSUT()
        await driver.setConnectError(DatabaseError.connectionFailed("Access denied for user 'u'@'localhost' (using password: YES)"))
        let config = makeConfig()
        await viewModel.connect(config: config)
        #expect(viewModel.isConnected == false)
        #expect(viewModel.classifiedError?.category == .authenticationFailed)
        #expect(viewModel.classifiedError?.recovery == .editConnection)
        #expect(viewModel.errorMessage?.contains("Access denied") == true)
        viewModel.requestEditConnection()
        #expect(viewModel.configPendingEdit?.id == config.id)
    }

    @Test func retryReconnectsAfterConnectFailure() async {
        let (viewModel, driver, _) = await makeSUT()
        await driver.setConnectError(DatabaseError.connectionFailed("Connection refused"))
        await viewModel.connect(config: makeConfig())
        #expect(viewModel.classifiedError?.category == .networkUnreachable)
        await driver.setConnectError(nil)
        await viewModel.retryLastAction()
        #expect(await driver.connectAttempts == 2)
        #expect(viewModel.isConnected == true)
        #expect(viewModel.classifiedError == nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func queryFailureClassifies() async {
        let (viewModel, _, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        await connection.setQueryError(DatabaseError.queryFailed("near \"SELEC\": syntax error"))
        viewModel.queryText = "SELECT * FROM missing_table"
        await viewModel.executeQuery()
        #expect(viewModel.classifiedError?.category == .syntaxError)
        #expect(viewModel.classifiedError?.recovery == DatabaseErrorRecovery.none)
        #expect(viewModel.queryResult == nil)
    }

    @Test func retryRerunsQueryWhenConnected() async {
        let (viewModel, _, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        await connection.setQueryError(DatabaseError.queryFailed("database is locked"))
        viewModel.queryText = "SELECT 1"
        await viewModel.executeQuery()
        #expect(viewModel.classifiedError?.category == .serverError)
        await connection.setQueryError(nil)
        await viewModel.retryLastAction()
        #expect(viewModel.classifiedError == nil)
        #expect(viewModel.queryResult?.rows == [[.integer(1)]])
    }

    @Test func clearingErrorMessageClearsClassification() async {
        let (viewModel, _, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        await connection.setQueryError(DatabaseError.queryFailed("no such table: t"))
        viewModel.queryText = "SELECT * FROM t"
        await viewModel.executeQuery()
        #expect(viewModel.classifiedError != nil)
        viewModel.errorMessage = nil
        #expect(viewModel.classifiedError == nil)
    }

    @Test func multiExecClassifiesPerStatement() async {
        let (viewModel, _, connection) = await makeSUT()
        await viewModel.connect(config: makeConfig())
        await connection.setFailPattern("FAIL")
        viewModel.queryText = "SELECT 1; SELECT * FROM FAIL"
        await viewModel.executeAllStatements()
        #expect(viewModel.multiExecutions.count == 2)
        #expect(viewModel.multiExecutions[0].succeeded)
        #expect(viewModel.multiExecutions[1].errorCategory == .syntaxError)
        #expect(viewModel.multiExecutions[1].errorMessage?.contains("no such table") == true)
    }

    @Test func executeWithoutConnectionClassifies() async {
        let (viewModel, _, _) = await makeSUT()
        viewModel.queryText = "SELECT 1"
        await viewModel.executeQuery()
        #expect(viewModel.classifiedError?.category == .connectionLost)
        #expect(viewModel.classifiedError?.recovery == .retry)
    }
}

private extension ErrorFakeDriver {
    func setConnectError(_ error: (any Error)?) {
        connectError = error
    }
}

private extension ErrorFakeConnection {
    func setQueryError(_ error: (any Error)?) {
        queryError = error
    }

    func setFailPattern(_ pattern: String?) {
        failPattern = pattern
    }
}