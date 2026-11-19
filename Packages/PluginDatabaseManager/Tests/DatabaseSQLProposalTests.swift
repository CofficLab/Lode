@testable import DatabaseManagerPlugin
import Foundation
import KitLLM
import ProviderLifecycleHooks
import Testing

private actor ProposalFakeConnection: DatabaseConnection {
    private var statements: [String] = []

    func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        statements.append(sql)
        return QueryResult(columns: [], rows: [], rowsAffected: 0)
    }

    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        statements.append(sql)
        return 0
    }

    func beginTransaction() async throws -> any DatabaseTransaction {
        ProposalFakeTransaction()
    }

    func close() async {}
    func isAlive() async -> Bool { true }
    func cancel() async {}

    func resetStatements() {
        statements.removeAll()
    }

    func statementCount() -> Int {
        statements.count
    }
}

private struct ProposalFakeTransaction: DatabaseTransaction {
    func commit() async throws {}
    func rollback() async throws {}
    func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
}

private actor ProposalFakeDriver: DatabaseDriver {
    nonisolated let type: DatabaseType = .postgresql
    private let connection: ProposalFakeConnection

    init(connection: ProposalFakeConnection) {
        self.connection = connection
    }

    func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        connection
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DatabaseSQLProposalTests {
    private func makeSUT() async -> (
        viewModel: DatabaseViewModel,
        connection: ProposalFakeConnection,
        history: QueryHistoryStore,
        configA: DatabaseConfig,
        configB: DatabaseConfig,
        cleanup: () -> Void
    ) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let connection = ProposalFakeConnection()
        await manager.register(driver: ProposalFakeDriver(connection: connection))
        let suite = "DatabaseSQLProposalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lode-proposal-history-\(UUID().uuidString).sqlite")
        let history = await Task.detached {
            QueryHistoryStore(databaseURL: historyURL, defaults: UserDefaults(suiteName: suite)!)
        }.value
        let viewModel = DatabaseViewModel(
            loadSavedConfigs: false,
            manager: manager,
            workspaceDefaults: defaults,
            historyStore: history
        )
        let configA = DatabaseConfig(name: "A", type: .postgresql, database: "db-a")
        let configB = DatabaseConfig(name: "B", type: .postgresql, database: "db-b")
        await viewModel.connect(config: configA)
        await connection.resetStatements()
        return (
            viewModel,
            connection,
            history,
            configA,
            configB,
            {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: historyURL)
            }
        )
    }

    private func seedCleanEditor(_ viewModel: DatabaseViewModel, text: String = "SELECT 1;") {
        viewModel.queryText = text
        viewModel.workspace.updateActive { tab in
            tab.text = text
            tab.savedText = text
        }
    }

    @Test("提案只回填当前编辑器并保留脏标记，不执行也不记历史")
    func proposalOnlyUpdatesEditor() async throws {
        let (viewModel, connection, history, config, _, cleanup) = await makeSUT()
        defer {
            DatabaseSQLProposalRuntime.shared.deactivate(viewModel: viewModel)
            cleanup()
        }
        #expect(viewModel.isConnected)
        seedCleanEditor(viewModel)
        DatabaseSQLProposalRuntime.shared.activate(viewModel: viewModel)
        let context = try #require(DatabaseSQLProposalRuntime.shared.prepareContext())
        let sql = "SELECT count(*) FROM users WHERE created_at >= CURRENT_DATE;"

        let receipt = try DatabaseSQLProposalRuntime.shared.apply(
            token: context.token,
            connectionID: config.id,
            queryTabID: context.queryTabID,
            sql: sql
        )

        #expect(!receipt.executed)
        #expect(viewModel.queryText == sql)
        #expect(viewModel.workspace.activeTab.text == sql)
        #expect(viewModel.workspace.activeTab.savedText == "SELECT 1;")
        #expect(viewModel.workspace.activeTab.isDirty)
        #expect(viewModel.queryResult == nil)
        #expect(viewModel.runningTabID == nil)
        #expect(await connection.statementCount() == 0)
        #expect(await history.count() == 0)
    }

    @Test("切换标签后旧提案不能覆盖新标签")
    func rejectsProposalAfterTabSwitch() async throws {
        let (viewModel, connection, _, config, _, cleanup) = await makeSUT()
        defer {
            DatabaseSQLProposalRuntime.shared.deactivate(viewModel: viewModel)
            cleanup()
        }
        seedCleanEditor(viewModel)
        DatabaseSQLProposalRuntime.shared.activate(viewModel: viewModel)
        let context = try #require(DatabaseSQLProposalRuntime.shared.prepareContext())
        let originalTabID = context.queryTabID
        viewModel.newQueryTab()

        #expect(throws: DatabaseSQLProposalError.staleProposal) {
            try DatabaseSQLProposalRuntime.shared.apply(
                token: context.token,
                connectionID: config.id,
                queryTabID: originalTabID,
                sql: "SELECT * FROM users;"
            )
        }
        #expect(viewModel.workspace.activeTabID != originalTabID)
        #expect(viewModel.queryText.isEmpty)
        #expect(viewModel.workspace.tab(id: originalTabID)?.text == "SELECT 1;")
        #expect(await connection.statementCount() == 0)
    }

    @Test("切换连接代际后旧提案失效")
    func rejectsProposalAfterConnectionSwitch() async throws {
        let (viewModel, connection, _, configA, configB, cleanup) = await makeSUT()
        defer {
            DatabaseSQLProposalRuntime.shared.deactivate(viewModel: viewModel)
            cleanup()
        }
        seedCleanEditor(viewModel)
        DatabaseSQLProposalRuntime.shared.activate(viewModel: viewModel)
        let context = try #require(DatabaseSQLProposalRuntime.shared.prepareContext())
        await viewModel.connect(config: configB)
        viewModel.queryText = "SELECT * FROM new_connection;"

        #expect(throws: DatabaseSQLProposalError.staleProposal) {
            try DatabaseSQLProposalRuntime.shared.apply(
                token: context.token,
                connectionID: configA.id,
                queryTabID: context.queryTabID,
                sql: "SELECT * FROM old_connection;"
            )
        }
        #expect(viewModel.selectedConfig?.id == configB.id)
        #expect(viewModel.queryText == "SELECT * FROM new_connection;")
        #expect(await connection.statementCount() > 0)
    }

    @Test("切换 schema 后旧提案失效")
    func rejectsProposalAfterSchemaSwitch() async throws {
        let (viewModel, _, _, config, _, cleanup) = await makeSUT()
        defer {
            DatabaseSQLProposalRuntime.shared.deactivate(viewModel: viewModel)
            cleanup()
        }
        seedCleanEditor(viewModel)
        DatabaseSQLProposalRuntime.shared.activate(viewModel: viewModel)
        let context = try #require(DatabaseSQLProposalRuntime.shared.prepareContext())
        await viewModel.switchSchema("analytics")
        #expect(viewModel.activeSchema == "analytics")

        #expect(throws: DatabaseSQLProposalError.staleProposal) {
            try DatabaseSQLProposalRuntime.shared.apply(
                token: context.token,
                connectionID: config.id,
                queryTabID: context.queryTabID,
                sql: "SELECT * FROM old_schema.users;"
            )
        }
        #expect(viewModel.queryText == "SELECT 1;")
    }

    @Test("用户继续编辑后迟到提案失效且令牌单次使用")
    func rejectsEditorChangesAndTokenReuse() async throws {
        let (viewModel, connection, _, config, _, cleanup) = await makeSUT()
        defer {
            DatabaseSQLProposalRuntime.shared.deactivate(viewModel: viewModel)
            cleanup()
        }
        seedCleanEditor(viewModel)
        DatabaseSQLProposalRuntime.shared.activate(viewModel: viewModel)
        let changed = try #require(DatabaseSQLProposalRuntime.shared.prepareContext())
        viewModel.queryText = "SELECT user_edit;"

        #expect(throws: DatabaseSQLProposalError.editorChanged) {
            try DatabaseSQLProposalRuntime.shared.apply(
                token: changed.token,
                connectionID: config.id,
                queryTabID: changed.queryTabID,
                sql: "SELECT generated;"
            )
        }
        #expect(viewModel.queryText == "SELECT user_edit;")

        let fresh = try #require(DatabaseSQLProposalRuntime.shared.prepareContext())
        _ = try DatabaseSQLProposalRuntime.shared.apply(
            token: fresh.token,
            connectionID: config.id,
            queryTabID: fresh.queryTabID,
            sql: "SELECT fresh;"
        )
        #expect(throws: DatabaseSQLProposalError.staleProposal) {
            try DatabaseSQLProposalRuntime.shared.apply(
                token: fresh.token,
                connectionID: config.id,
                queryTabID: fresh.queryTabID,
                sql: "SELECT overwritten;"
            )
        }
        #expect(viewModel.queryText == "SELECT fresh;")
        #expect(await connection.statementCount() == 0)
    }

    @Test("LLM 请求注入当前方言与提案目标，停用后不再注入")
    func injectsDatabaseContextOnlyWhileActive() async throws {
        let (viewModel, _, _, config, _, cleanup) = await makeSUT()
        defer {
            DatabaseSQLProposalRuntime.shared.deactivate(viewModel: viewModel)
            cleanup()
        }
        DatabaseSQLProposalRuntime.shared.activate(viewModel: viewModel)
        let hook = DatabaseAgentContextHook()
        let original = WillSendToLLMContext(
            messages: [LLMMessage(role: .user, content: "How many users registered today?")],
            conversationID: UUID()
        )

        let injected = hook.apply(to: original)
        #expect(injected.messages.count == 2)
        let prompt = try #require(injected.messages.first)
        #expect(prompt.role == .system)
        #expect(prompt.content.contains(config.id.uuidString))
        #expect(prompt.content.contains("PostgreSQL"))
        #expect(prompt.content.contains("database_propose_sql"))
        #expect(prompt.content.contains("never executes SQL"))
        #expect(injected.messages.last == original.messages.first)

        DatabaseSQLProposalRuntime.shared.deactivate(viewModel: viewModel)
        #expect(hook.apply(to: original).messages == original.messages)
    }
}
