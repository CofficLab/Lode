import ProviderEditor
import Foundation
import LumiLoggingKit
import Combine

@MainActor
public class DatabaseViewModel: ObservableObject, SuperLog {
    public nonisolated static let emoji = "🗄️"
    public nonisolated static let verbose: Bool = false
    @Published var configs: [DatabaseConfig] = []
    @Published var selectedConfig: DatabaseConfig?
    @Published var queryText: String = "SELECT * FROM sqlite_master;"
    @Published var queryResult: QueryResult?
    @Published var errorMessage: String? {
        didSet { if errorMessage == nil { classifiedError = nil } }
    }
    /// 当前错误的语义分类（本地化标题 + 恢复动作），与 ``errorMessage`` 同步。
    @Published public private(set) var classifiedError: ClassifiedDatabaseError?
    /// 待编辑的连接；错误恢复动作「编辑连接」会置位并弹出表单。
    @Published public var configPendingEdit: DatabaseConfig?
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var redisKeys: [String] = []
    @Published var sqliteTables: [String] = []
    @Published var selectedSQLiteTable: String?
    /// 侧边栏当前展示的内容：数据浏览（Tables/Keys）或连接列表。
    @Published public var sidebarMode: DatabaseSidebarMode = .browser

    /// 结构元数据缓存（表/列/索引等），侧边栏对象树与结构 Tab 共用。
    public let schemaCache = SchemaCacheService()

    /// 右侧 Inspector 是否可见（结构详情 / ER 图 / EXPLAIN 等将放在这里）。
    @Published public var inspectorVisible: Bool = false

    // MARK: - 表浏览状态（统一分页）

    /// 当前在主区打开的表/视图对象；nil 表示未打开（显示 SQL 编辑器）。
    @Published public var openTableObject: DatabaseObject?
    /// 当前打开对象的完整结构，供 Inspector 与数据编辑共用。
    @Published public private(set) var selectedTableSchema: TableSchema?
    /// 表结构是否正在加载。
    @Published public private(set) var isLoadingTableSchema: Bool = false
    /// 表结构加载失败信息；不覆盖查询区的通用错误。
    @Published public private(set) var tableSchemaError: String?
    /// 当前表结构的暂存变更；必须经预览确认后才会执行。
    @Published public private(set) var schemaChangeManager: SchemaChangeManager?
    @Published public var showSchemaChangePreview: Bool = false
    /// 当前页码（从 0 起）。
    @Published public var tablePage: Int = 0
    /// 每页行数。
    @Published public var tablePageSize: Int = 100
    /// 表的总行数（精确 COUNT，后台异步填充；nil 表示未知）。
    @Published public var tableRowCount: Int?
    /// 服务端排序（列名 + 方向）；nil 表示不排序。
    @Published public var tableOrderBy: (column: String, ascending: Bool)?
    /// 当前表的服务端筛选（条件组合或 raw WHERE）；空表示不过滤。
    @Published public var tableFilter: TableFilter = .empty
    /// 是否展开筛选面板。
    @Published public var showFilterPanel: Bool = false
    /// NULL 单元格显示为 ⟨NULL⟩（否则显示 NULL）；设置持久化到 UserDefaults。
    @Published public var useNullSymbol: Bool = UserDefaults.standard.bool(forKey: "DatabaseManager.useNullSymbol") {
        didSet { UserDefaults.standard.set(useNullSymbol, forKey: "DatabaseManager.useNullSymbol") }
    }

    /// 当前打开表的变更跟踪队列；未打开表时为 nil。
    @Published public var changeManager: TableChangeManager?
    /// 是否正在展示「Preview SQL」面板。
    @Published public var showChangePreview: Bool = false
    /// 提交前乐观锁检测到的行冲突；非空时弹出冲突解决面板，暂停写入。
    @Published public private(set) var pendingConflicts: [RowConflict] = []
    /// 是否正在展示冲突解决面板。
    @Published public var showConflictSheet: Bool = false

    /// 待确认的写操作（confirmWrites 档）；非 nil 时弹出确认对话框，写流程挂起等待用户决定。
    @Published public private(set) var writeConfirmation: WriteConfirmationRequest?
    /// 写确认的挂起续体；用户决定后恢复写流程。
    private var writeConfirmationContinuation: CheckedContinuation<Bool, Never>?

    /// 多语句执行的结果（每语句一条）；为空时表示当前是单语句模式。
    @Published public var multiExecutions: [StatementExecution] = []
    /// 多结果当前选中的 tab 索引。
    @Published public var selectedExecutionIndex: Int = 0
    /// ⌘⇧↩ 批量执行策略：逐句继续（默认）或包裹事务失败回滚。
    @Published public var batchPolicy: BatchExecutionPolicy = .continueOnError
    /// 最近一次批量执行是否因失败而整体回滚（供结果区显示提示）。
    @Published public private(set) var lastBatchRolledBack = false
    /// 编辑器光标在 ``queryText`` 中的 UTF-16 偏移；由嵌入式编辑器回写，`NSNotFound` 表示未知。
    @Published public var editorCursorLocation: Int = NSNotFound

    // MARK: - 编辑器查询行数上限与增量加载

    /// 编辑器查询的默认行数上限；用户 SQL 自带 LIMIT 时不覆盖。0 表示不限制。
    @Published public var queryRowLimit: Int = 1000
    /// 当前编辑器结果的基础 SQL（去尾分号）；nil 表示不可增量加载。
    @Published public private(set) var editorBaseSQL: String?
    /// 当前结果是否还有更多行可加载（注入了 LIMIT 且上一页取满）。
    @Published public private(set) var editorHasMore: Bool = false
    /// 已取回的行数，作为下一次加载的 OFFSET。
    @Published public private(set) var editorFetchedRows: Int = 0
    /// 增量加载进行中。
    @Published public private(set) var isLoadingMore: Bool = false
    /// 执行序列号：每次新执行自增，迟到的旧结果（含增量加载）凭此丢弃。
    private var executionSequence: UInt64 = 0

    // MARK: - 连接健康与自动重连

    /// 后台心跳任务（仅网络引擎）；未连接或 SQLite 时为 nil。
    private var heartbeatTask: Task<Void, Never>?
    /// 本次断线是否已尝试过一次自动重连；连接成功后重置。
    private var didAttemptAutoReconnect = false
    /// 心跳间隔（秒）。
    static let heartbeatInterval: TimeInterval = 30
    /// 心跳是否激活（测试用）。
    var isHeartbeatActive: Bool { heartbeatTask != nil }

    /// 是否可为当前编辑器结果加载更多行。
    public var canLoadMoreEditorResults: Bool {
        editorBaseSQL != nil && editorHasMore && !isLoading && !isLoadingMore
    }

    /// 只读对象定义（索引/触发器/例程）的展示状态；非 nil 时弹出定义面板。
    @Published public var objectDefinition: ObjectDefinitionDisplay?

    /// 对象定义面板的展示模型。
    public struct ObjectDefinitionDisplay: Identifiable, Sendable {
        public let id: String
        public let object: DatabaseObject
        public var ddl: String?
        public var isLoading: Bool
        public var errorMessage: String?

        public init(id: String, object: DatabaseObject, ddl: String? = nil, isLoading: Bool = true, errorMessage: String? = nil) {
            self.id = id
            self.object = object
            self.ddl = ddl
            self.isLoading = isLoading
            self.errorMessage = errorMessage
        }
    }

    /// 查询历史（UI 通过此状态渲染）。
    @Published public var history: [QueryHistoryEntry] = []
    /// 是否显示历史面板。
    @Published public var showHistory: Bool = false
    /// 历史搜索关键字。
    @Published public var historySearchText: String = ""

    private let historyStore = QueryHistoryStore.shared

    public func toggleInspector() {
        inspectorVisible.toggle()
    }

    private let manager: DatabaseManagerCore

    /// 宿主注入的嵌入式编辑器能力（语法高亮）；nil 时 View 退回 TextEditor。
    @Published public var embeddedEditorProvider: (any EditorEmbeddedEditorProviding)?
    nonisolated(unsafe) private var connectedConfigId: UUID?
    /// 最近一次尝试连接的配置（含失败的），供错误恢复「重试」重连。
    private var lastAttemptedConfig: DatabaseConfig?
    /// 连接代际：每次连接/断开都自增。
    ///
    /// 查询、加载键列表等异步操作返回时必须校验代际，避免旧连接（或慢查询）
    /// 的结果覆盖掉新连接已经写入的状态。
    private var connectionGeneration: Int = 0
    /// 是否已尝试过自动重连（每次启动只自动连一次）。
    private var didAutoConnect = false

    public convenience init() {
        self.init(loadSavedConfigs: true)
    }

    /// 测试专用初始化：`loadSavedConfigs == false` 时跳过从 UserDefaults 读取已存配置，
    /// 始终使用一份独立的内存 demo 连接，避免并行测试共享进程级 UserDefaults 串扰。
    /// `manager` 可注入，用于构造可控延迟的驱动复现连接竞态。
    public init(loadSavedConfigs: Bool, manager: DatabaseManagerCore = .shared) {
        self.manager = manager
        Task {
            await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        }
        if Self.verbose {
            if DatabaseManagerPluginSupport.verbose {
                            DatabaseManagerPluginSupport.logger.info("\(Self.t)初始化数据库视图模型")
            }
        }
        // 恢复上次保存的连接；首次使用时保留一个内存 demo 连接
        let savedConfigs = loadSavedConfigs ? DatabaseConnectionStore.loadConfigs() : []
        if savedConfigs.isEmpty {
            let demoConfig = DatabaseConfig(name: "Demo SQLite", type: .sqlite, database: ":memory:")
            configs = [demoConfig]
        } else {
            configs = savedConfigs
        }
        for config in configs {
            Task {
                await DatabaseAgentConnectionRegistry.shared.upsert(config)
            }
        }
    }

    deinit {
        heartbeatTask?.cancel()
        let configId = connectedConfigId
        Task { [manager, configId] in
            guard let configId else { return }
            await manager.disconnect(configId: configId)
        }
    }

    public func addConfig(_ config: DatabaseConfig) {
        configs.append(config)
        DatabaseConnectionStore.saveConfigs(configs)
        Task {
            await DatabaseAgentConnectionRegistry.shared.upsert(config)
        }
    }

    /// 编辑已存在的连接配置（保留 id）。若表单里密码留空，沿用已存密码，避免误清空。
    /// 若当前正连着该连接，则用新配置断开重连。
    public func updateConfig(_ config: DatabaseConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        var updated = config
        if (updated.password?.isEmpty ?? true) {
            updated.password = configs[index].password
        }
        let wasConnected = (selectedConfig?.id == config.id && isConnected)
        configs[index] = updated
        DatabaseConnectionStore.saveConfigs(configs)
        Task { await DatabaseAgentConnectionRegistry.shared.upsert(updated) }

        if wasConnected {
            Task {
                await disconnect()
                await connect(config: updated)
            }
        } else if selectedConfig?.id == config.id {
            // 未连接但已选中：同步选中引用，让侧边栏/UI 立即反映新名称等
            selectedConfig = updated
        }
    }

    /// 移除一个已保存的连接。如果删除的是当前连接，先断开再删除。
    public func removeConfig(_ config: DatabaseConfig) {
        if selectedConfig?.id == config.id {
            Task { await disconnect() }
        }
        configs.removeAll { $0.id == config.id }
        DatabaseConnectionStore.deletePassword(for: config.id)
        DatabaseConnectionStore.saveConfigs(configs)
        Task {
            await DatabaseAgentConnectionRegistry.shared.remove(id: config.id)
        }
    }

    /// 仅在首次进入数据库 UI 时尝试一次自动重连上次使用的连接。
    /// 显式断开后 `lastSelectedConfigID` 会被清空，因此断开过的连接不会自动连回来。
    public func autoConnectIfNeeded() {
        guard !didAutoConnect, !isConnected else { return }
        didAutoConnect = true
        guard let lastID = DatabaseConnectionStore.lastSelectedConfigID,
              let config = configs.first(where: { $0.id == lastID }) else { return }
        Task { await connect(config: config) }
    }
    
    /// 测试连接（供连接表单使用），复用内置驱动注册逻辑。
    public func testConnection(config: DatabaseConfig) async throws {
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        try await manager.probe(config: config)
    }

    public func connect(config: DatabaseConfig) async {
        await connect(config: config, isReconnect: false)
    }

    /// 建立连接。`isReconnect` 为 true 时保留编辑器文本与当前打开表的上下文。
    private func connect(config: DatabaseConfig, isReconnect: Bool) async {
        lastAttemptedConfig = config
        stopHeartbeat()
        let preservedQueryText = queryText
        let preservedTable = openTableObject
        let generation = beginConnectionGeneration()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        guard connectionGeneration == generation else { return }
        await DatabaseAgentConnectionRegistry.shared.upsert(config)
        guard connectionGeneration == generation else { return }
        if Self.verbose {
            if DatabaseManagerPluginSupport.verbose {
                            DatabaseManagerPluginSupport.logger.info("\(self.t)连接数据库: \(config.name)")
            }
        }
        isLoading = true
        errorMessage = nil
        do {
            _ = try await manager.connect(config: config)
            // 连接期间用户已切换/断开：回收刚建立的连接，不再写任何状态。
            guard connectionGeneration == generation else {
                await manager.disconnect(configId: config.id)
                return
            }
            let previousConfigId = selectedConfig?.id
            selectedConfig = config
            connectedConfigId = config.id
            isConnected = true
            queryRowLimit = config.type.capabilities.defaultQueryLimit
            resetEditorPaging()
            queryResult = nil
            redisKeys = []
            sqliteTables = []
            selectedSQLiteTable = nil
            openTableObject = nil
            selectedTableSchema = nil
            tableSchemaError = nil
            tableRowCount = nil
            changeManager = nil
            pendingConflicts = []
            showConflictSheet = false
            cancelPendingWriteConfirmation()
            schemaChangeManager = nil
            // 切换连接时清掉旧连接的结构缓存
            schemaCache.invalidate(configId: config.id)
            // 记住这次连接，下次自动重连
            DatabaseConnectionStore.lastSelectedConfigID = config.id
            
            // 根据类型设置默认查询/命令；重连时保留用户正在编辑的文本。
            switch config.type {
            case .postgresql:
                if !isReconnect {
                    queryText = "SELECT table_name FROM information_schema.tables WHERE table_schema='public';"
                }
            case .mysql:
                if !isReconnect {
                    queryText = "SHOW TABLES;"
                }
            case .redis:
                if !isReconnect {
                    queryText = "SCAN 0 MATCH * COUNT 50"
                }
                await loadRedisKeys()
            case .sqlite:
                if !isReconnect, config.database == ":memory:" {
                    try await initDemoData(configId: config.id)
                }
                await loadSQLiteTables()
            }

            if isReconnect {
                queryText = preservedQueryText
                // 恢复断线前打开的表/视图上下文（结构 + 当前页数据）。
                if let table = preservedTable {
                    switch table.kind {
                    case .table, .view, .materializedView:
                        openTableObject = table
                        await loadSelectedTableSchema()
                        await loadTablePage()
                    default:
                        break
                    }
                }
            }

            // 为侧边栏对象树预加载可见分类（表/视图/例程），MySQL/PG 由此不再空白。
            await refreshSidebarObjects()

            guard connectionGeneration == generation else { return }

            didAttemptAutoReconnect = false
            startHeartbeat()

            if let previousConfigId, previousConfigId != config.id {
                await manager.disconnect(configId: previousConfigId)
            }

            if Self.verbose {
                if DatabaseManagerPluginSupport.verbose {
                                    DatabaseManagerPluginSupport.logger.info("\(self.t)数据库连接成功: \(config.name)")
                }
            }
        } catch {
            guard connectionGeneration == generation else { return }
            if DatabaseManagerPluginSupport.verbose {
                            DatabaseManagerPluginSupport.logger.error("\(self.t)数据库连接失败: \(error.localizedDescription)")
            }
            // 重连失败时旧连接已不可用，必须落回未连接态，避免界面误判仍在线。
            isConnected = false
            stopHeartbeat()
            presentError(error)
        }
        isLoading = false
    }

    public func disconnect() async {
        guard let config = selectedConfig else { return }
        stopHeartbeat()
        let generation = beginConnectionGeneration()
        if Self.verbose {
            if DatabaseManagerPluginSupport.verbose {
                            DatabaseManagerPluginSupport.logger.info("\(self.t)断开数据库连接: \(config.name)")
            }
        }
        await manager.disconnect(configId: config.id)
        // 断开等待期间又建立了新连接：不要清掉新连接的状态。
        guard connectionGeneration == generation else { return }
        isConnected = false
        isLoading = false
        selectedConfig = nil
        connectedConfigId = nil
        queryResult = nil
        redisKeys = []
        sqliteTables = []
        selectedSQLiteTable = nil
        openTableObject = nil
        selectedTableSchema = nil
        tableSchemaError = nil
        tableRowCount = nil
        changeManager = nil
        pendingConflicts = []
        showConflictSheet = false
        cancelPendingWriteConfirmation()
        schemaChangeManager = nil
        schemaCache.invalidate(configId: config.id)
        // 显式断开后，下次不再自动重连这个连接
        DatabaseConnectionStore.lastSelectedConfigID = nil
    }

    /// 开始一次新的连接代际，使此前所有在途异步操作失效。
    private func beginConnectionGeneration() -> Int {
        connectionGeneration += 1
        return connectionGeneration
    }

    /// 异步操作返回后校验：仍是同一代、同一条连接时才允许写回状态。
    private func isCurrentConnection(_ generation: Int, configId: UUID) -> Bool {
        connectionGeneration == generation && connectedConfigId == configId
    }

    /// 请求中止当前连接上正在执行的语句。
    /// 正在执行的调用会抛出 ``DatabaseError/cancelled`` 并走既有错误回写路径。
    public func cancelRunningQuery() async {
        guard let configId = connectedConfigId,
              let connection = await manager.getConnection(for: configId) else { return }
        await connection.cancel()
    }

    /// 统一错误入口：分类后同步写入 ``classifiedError`` 与 ``errorMessage``。
    private func presentError(_ error: any Error) {
        let classified = DatabaseErrorClassifier.classify(error)
        classifiedError = classified
        errorMessage = classified.detail
    }

    /// 错误恢复「重试」：已连接时重跑当前编辑器语句，否则重连最近一次配置。
    public func retryLastAction() async {
        errorMessage = nil
        if isConnected, selectedConfig != nil {
            await executeQuery()
        } else if let config = selectedConfig ?? lastAttemptedConfig {
            // 重连保留编辑器文本与打开表上下文，避免重试把用户查询重置成默认语句。
            await connect(config: config, isReconnect: true)
        }
    }

    /// 错误恢复「编辑连接」：弹出当前（或最近尝试的）连接的编辑表单。
    public func requestEditConnection() {
        configPendingEdit = selectedConfig ?? lastAttemptedConfig
    }

    // MARK: - 心跳与断线重连

    private func startHeartbeat() {
        stopHeartbeat()
        guard let config = selectedConfig, config.type != .sqlite else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.heartbeatInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.checkConnectionHealth()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// 心跳探测：经连接池用独立连接发 SELECT 1 / PING，
    /// 不排在主连接的长查询后面；执行中（isLoading）跳过以免误判。
    func checkConnectionHealth() async {
        guard isConnected, !isLoading, let config = selectedConfig else { return }
        let generation = connectionGeneration
        let probeSQL = config.type == .redis ? "PING" : "SELECT 1"
        let healthy: Bool
        do {
            _ = try await manager.withConnection(for: config) { connection in
                try await connection.query(probeSQL, params: nil)
            }
            healthy = true
        } catch {
            healthy = false
        }
        guard connectionGeneration == generation, isConnected, !isLoading else { return }
        if !healthy {
            await handleConnectionLoss(generation: generation)
        }
    }

    /// 断线后的一次自动重连；失败则给出分类错误，不再反复尝试。
    private func handleConnectionLoss(generation: Int) async {
        guard let config = selectedConfig, connectionGeneration == generation else { return }
        if didAttemptAutoReconnect {
            isConnected = false
            stopHeartbeat()
            presentError(DatabaseError.connectionFailed("Connection lost; automatic reconnect failed"))
            return
        }
        didAttemptAutoReconnect = true
        await connect(config: config, isReconnect: true)
        if !isConnected {
            stopHeartbeat()
        }
    }

    public func executeQuery() async {
        await executeQuery(isRetry: false, sqlOverride: nil)
    }

    /// ⌘↩：执行光标所在语句。光标未知或落在语句间隙时退回执行整段文本（兼容降级编辑器）。
    public func executeStatementAtCursor() async {
        let cursor = editorCursorLocation
        if cursor != NSNotFound,
           let stmt = SQLStatementParser.statement(atCursor: cursor, in: queryText) {
            await executeQuery(isRetry: false, sqlOverride: stmt)
        } else {
            await executeQuery(isRetry: false, sqlOverride: nil)
        }
    }

    /// `isRetry` 为 true 时不再触发断线重连，避免重连-重试无限循环。
    /// `sqlOverride` 非 nil 时执行该语句而非整段 ``queryText``（光标单句执行）。
    private func executeQuery(isRetry: Bool, sqlOverride: String?) async {
        let generation = connectionGeneration
        let sql = sqlOverride ?? queryText
        guard let config = selectedConfig else {
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            if DatabaseManagerPluginSupport.verbose {
                            DatabaseManagerPluginSupport.logger.error("\(self.t)执行查询失败: 未连接到数据库")
            }
            return
        }
        guard let connection = await manager.getConnection(for: config.id) else {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            if DatabaseManagerPluginSupport.verbose {
                            DatabaseManagerPluginSupport.logger.error("\(self.t)执行查询失败: 未连接到数据库")
            }
            return
        }
        // 取连接期间用户可能已经切走：旧连接的结果不允许再落到界面上。
        guard isCurrentConnection(generation, configId: config.id) else { return }

        // 写权限闸门：readOnly 拒绝、confirmWrites 弹确认（读语句直接放行）。
        switch await authorizeWrites([sql], type: config.type, kind: .query) {
        case .authorized: break
        case .cancelled: return
        case .blocked: presentReadOnlyError(); return
        }

        if Self.verbose {
            if DatabaseManagerPluginSupport.verbose {
                            DatabaseManagerPluginSupport.logger.info("\(self.t)执行查询: \(sql.prefix(50))...")
            }
        }

        isLoading = true
        errorMessage = nil
        // 单语句模式：清掉多结果 tab 栏。
        multiExecutions = []
        resetEditorPaging()
        executionSequence += 1
        let sequence = executionSequence

        do {
            // Redis 读命令与 SQL 读语句共用同一判定，避免两处前缀列表漂移。
            if Self.isReadStatement(sql, type: config.type) {
                // Redis 命令不是 SQL，不能注入 LIMIT。
                let limited = config.type == .redis
                    ? SQLQueryLimitResult(sql: sql, injectedLimit: nil, baseSQL: nil)
                    : SQLQueryLimiter.apply(sql, limit: queryRowLimit)
                let result = try await connection.query(limited.sql, params: nil)
                guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }
                queryResult = result
                editorBaseSQL = limited.baseSQL
                editorFetchedRows = result.rows.count
                if let injected = limited.injectedLimit {
                    editorHasMore = result.rows.count >= injected
                }
                if Self.verbose {
                    if DatabaseManagerPluginSupport.verbose {
                                                DatabaseManagerPluginSupport.logger.info("\(self.t)查询成功，返回 \(result.rows.count) 行")
                    }
                }
            } else {
                let affected = try await connection.execute(sql, params: nil)
                guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }
                queryResult = QueryResult(columns: ["Result"], rows: [[.string("Success. Rows affected: \(affected)")]], rowsAffected: affected)
                if Self.verbose {
                    if DatabaseManagerPluginSupport.verbose {
                                                DatabaseManagerPluginSupport.logger.info("\(self.t)执行成功，影响 \(affected) 行")
                    }
                }
            }
        } catch {
            guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }
            if DatabaseManagerPluginSupport.verbose {
                            DatabaseManagerPluginSupport.logger.error("\(self.t)查询执行失败: \(error.localizedDescription)")
            }
            // 断线类错误：一次自动重连并重跑当前语句（保留编辑器上下文）。
            let classified = DatabaseErrorClassifier.classify(error)
            if classified.category == .connectionLost, !isRetry, !didAttemptAutoReconnect {
                didAttemptAutoReconnect = true
                await connect(config: config, isReconnect: true)
                if isConnected {
                    isLoading = false
                    await executeQuery(isRetry: true, sqlOverride: sqlOverride)
                    return
                }
            }
            presentError(error)
        }
        guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }
        isLoading = false
        // 成功或失败都记历史（失败时用户可能想重试/修改）。
        await recordExecutedSQLs([sql], config: config)
    }

    /// 为当前编辑器结果追加下一页（基础 SQL + LIMIT/OFFSET 窗口）。
    ///
    /// 仅当执行时注入了默认 LIMIT 才可用；用户自带 LIMIT 的查询不提供增量加载。
    public func loadMoreEditorResults() async {
        guard let baseSQL = editorBaseSQL, editorHasMore,
              let config = selectedConfig, config.type != .redis else { return }
        let generation = connectionGeneration
        let sequence = executionSequence
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }

        isLoadingMore = true
        let pageSize = max(queryRowLimit, 1)
        let sql = "\(baseSQL)\nLIMIT \(pageSize) OFFSET \(editorFetchedRows)"
        do {
            let result = try await connection.query(sql, params: nil)
            guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else {
                isLoadingMore = false
                return
            }
            if var current = queryResult {
                current.rows.append(contentsOf: result.rows)
                queryResult = current
            }
            editorFetchedRows += result.rows.count
            editorHasMore = result.rows.count >= pageSize
        } catch {
            guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else {
                isLoadingMore = false
                return
            }
            presentError(error)
        }
        isLoadingMore = false
    }

    private func resetEditorPaging() {
        editorBaseSQL = nil
        editorHasMore = false
        editorFetchedRows = 0
    }

    /// 把 `queryText` 按 `;` 拆成多条语句依次执行（事务不包裹：跨引擎语义不一致）。
    ///
    /// - 每条语句独立计时、独立捕获结果/错误；
    /// - 任一语句失败仍继续执行后续语句；
    /// - 结果填入 ``multiExecutions``，同时 ``queryResult`` 指向最后一条成功语句的结果，
    ///   保持单结果视图的向后兼容。
    public func executeAllStatements() async {
        let statements = SQLStatementParser.split(queryText)
        guard !statements.isEmpty else { return }
        // 单条语句走既有路径（保持行为一致，也避免多结果 UI 在单语句时显得啰嗦）。
        if statements.count == 1 {
            await executeQuery()
            return
        }

        let generation = connectionGeneration
        guard let config = selectedConfig,
              let connection = await manager.getConnection(for: config.id) else {
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }

        // 写权限闸门：批量中任一写语句即触发（readOnly 整批拒绝、confirmWrites 确认一次）。
        switch await authorizeWrites(statements, type: config.type, kind: .batch) {
        case .authorized: break
        case .cancelled: return
        case .blocked: presentReadOnlyError(); return
        }

        isLoading = true
        errorMessage = nil
        lastBatchRolledBack = false
        multiExecutions = []
        queryResult = nil
        resetEditorPaging()
        executionSequence += 1

        if batchPolicy == .wrapInTransaction {
            await executeBatchInTransaction(
                statements: statements, config: config, connection: connection, generation: generation
            )
            return
        }

        var executions: [StatementExecution] = []
        var lastSuccess: QueryResult?

        for stmt in statements {
            let start = Date()
            var exec = StatementExecution(sql: stmt)
            do {
                if Self.isReadStatement(stmt, type: config.type) {
                    let limited = config.type == .redis
                        ? SQLQueryLimitResult(sql: stmt, injectedLimit: nil, baseSQL: nil)
                        : SQLQueryLimiter.apply(stmt, limit: queryRowLimit)
                    let result = try await connection.query(limited.sql, params: nil)
                    guard isCurrentConnection(generation, configId: config.id) else { return }
                    exec.result = result
                    lastSuccess = result
                } else {
                    let affected = try await connection.execute(stmt, params: nil)
                    guard isCurrentConnection(generation, configId: config.id) else { return }
                    let result = QueryResult(
                        columns: ["Result"],
                        rows: [[.string("OK. Rows affected: \(affected)")]],
                        rowsAffected: affected
                    )
                    exec.result = result
                    lastSuccess = result
                }
            } catch {
                guard isCurrentConnection(generation, configId: config.id) else { return }
                let classified = DatabaseErrorClassifier.classify(error)
                exec.errorMessage = classified.detail
                exec.errorCategory = classified.category
                if case DatabaseError.cancelled = error {
                    exec.durationMs = Date().timeIntervalSince(start) * 1000
                    executions.append(exec)
                    break
                }
            }
            exec.durationMs = Date().timeIntervalSince(start) * 1000
            executions.append(exec)
        }

        multiExecutions = executions
        queryResult = lastSuccess
        selectedExecutionIndex = 0
        isLoading = false
        await recordExecutedSQLs(statements, config: config)
    }

    /// 包裹事务的批量执行：任一语句失败即整体回滚并停止；全部成功才提交。
    ///
    /// SQL 引擎（MySQL/PG/SQLite）的读语句经同一连接的 `query` 执行（处于事务内），
    /// 写语句经事务 `execute`。Redis 走 MULTI/EXEC：所有命令入队，读命令返回 QUEUED，
    /// 真实回复在 EXEC 时产生，故本路径不逐句展示 Redis 读结果（MULTI 语义单独处理）。
    private func executeBatchInTransaction(
        statements: [String],
        config: DatabaseConfig,
        connection: any DatabaseConnection,
        generation: Int
    ) async {
        var executions: [StatementExecution] = []
        var lastSuccess: QueryResult?

        let transaction: any DatabaseTransaction
        do {
            transaction = try await connection.beginTransaction()
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            presentError(error)
            isLoading = false
            return
        }

        var failed = false
        for stmt in statements {
            let start = Date()
            var exec = StatementExecution(sql: stmt)
            do {
                if config.type == .redis {
                    let affected = try await transaction.execute(stmt, params: nil)
                    guard isCurrentConnection(generation, configId: config.id) else {
                        try? await transaction.rollback(); return
                    }
                    exec.result = QueryResult(columns: ["Result"], rows: [[.string("QUEUED")]], rowsAffected: affected)
                } else if Self.isReadStatement(stmt, type: config.type) {
                    let limited = SQLQueryLimiter.apply(stmt, limit: queryRowLimit)
                    let result = try await connection.query(limited.sql, params: nil)
                    guard isCurrentConnection(generation, configId: config.id) else {
                        try? await transaction.rollback(); return
                    }
                    exec.result = result
                    lastSuccess = result
                } else {
                    let affected = try await transaction.execute(stmt, params: nil)
                    guard isCurrentConnection(generation, configId: config.id) else {
                        try? await transaction.rollback(); return
                    }
                    let result = QueryResult(
                        columns: ["Result"],
                        rows: [[.string("OK. Rows affected: \(affected)")]],
                        rowsAffected: affected
                    )
                    exec.result = result
                    lastSuccess = result
                }
            } catch {
                guard isCurrentConnection(generation, configId: config.id) else {
                    try? await transaction.rollback(); return
                }
                let classified = DatabaseErrorClassifier.classify(error)
                exec.errorMessage = classified.detail
                exec.errorCategory = classified.category
                exec.durationMs = Date().timeIntervalSince(start) * 1000
                executions.append(exec)
                failed = true
                break
            }
            exec.durationMs = Date().timeIntervalSince(start) * 1000
            executions.append(exec)
        }

        if failed {
            try? await transaction.rollback()
            lastBatchRolledBack = true
        } else {
            do {
                try await transaction.commit()
            } catch {
                guard isCurrentConnection(generation, configId: config.id) else { return }
                // SQL 引擎 COMMIT 失败可回滚；Redis EXEC 非原子回滚，不宣称已回滚。
                if config.type != .redis {
                    try? await transaction.rollback()
                    lastBatchRolledBack = true
                }
                presentError(error)
            }
        }

        guard isCurrentConnection(generation, configId: config.id) else { return }
        multiExecutions = executions
        queryResult = lastSuccess
        selectedExecutionIndex = 0
        isLoading = false
        await recordExecutedSQLs(statements, config: config)
    }

    /// 判断一条 SQL 是否为"读"语句（走 query 路径）而非"写"（走 execute 路径）。
    public static func isReadStatement(_ sql: String, type: DatabaseType) -> Bool {
        if type == .redis {
            let upper = sql.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return upper.hasPrefix("GET") || upper.hasPrefix("SCAN") || upper.hasPrefix("HGET")
                || upper.hasPrefix("LRANGE") || upper.hasPrefix("SMEMBERS") || upper.hasPrefix("ZRANGE")
        }
        let upper = SQLStatementParser.stripLiteralsAndComments(sql)
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return upper.hasPrefix("SELECT") || upper.hasPrefix("PRAGMA")
            || upper.hasPrefix("SHOW") || upper.hasPrefix("DESCRIBE")
            // CTE 查询与执行计划都产生结果行。
            || upper.hasPrefix("WITH") || upper.hasPrefix("EXPLAIN")
            // DML ... RETURNING 也产生结果行，必须走 query 才能把返回行展示出来。
            || upper.contains("RETURNING")
    }

    // MARK: - 查询历史

    /// 加载最近 N 条历史到 ``history``。
    public func loadRecentHistory(limit: Int = 100) async {
        history = await historyStore.recent(limit: limit)
    }

    /// 按关键字搜索历史。
    public func searchHistory(_ query: String) async {
        historySearchText = query
        history = await historyStore.search(query)
    }

    /// 把一条历史条目载入编辑器（替换 queryText）。
    public func loadHistoryEntry(_ entry: QueryHistoryEntry) {
        queryText = entry.sql
        showHistory = false
    }

    /// 删除某条历史。
    public func deleteHistoryEntry(_ entry: QueryHistoryEntry) async {
        await historyStore.delete(id: entry.id)
        await loadRecentHistory()
    }

    /// 清空全部历史。
    public func clearHistory() async {
        await historyStore.clear()
        history.removeAll()
    }

    /// 记录已执行的 SQL（多语句时按语句逐条记）。
    ///
    /// `config` 由调用方在执行前快照传入：查询返回时连接可能已经切换，
    /// 历史必须归属真正执行它的连接。
    private func recordExecutedSQLs(_ statements: [String], config: DatabaseConfig) async {
        for sql in statements {
            await historyStore.record(sql: sql, configName: config.name, database: config.database)
        }
        await loadRecentHistory()
    }

    /// 加载 Redis 键列表（循环 SCAN 直到游标归零，带安全上限避免巨型键空间卡死）。
    public func loadRedisKeys() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type == .redis else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        guard let redis = connection as? RedisConnection else {
            presentError(DatabaseError.connectionFailed("Unexpected Redis connection type"))
            return
        }
        do {
            var cursor = "0"
            var keys: [String] = []
            /// 单次加载的安全上限，避免在生产键空间（数百万键）里无止境扫描。
            let safetyCap = 10_000
            repeat {
                let step = try await redis.scanKeys(cursor: cursor, match: "*", count: 200)
                guard isCurrentConnection(generation, configId: config.id) else { return }
                keys.append(contentsOf: step.keys)
                cursor = step.nextCursor
            } while cursor != "0" && keys.count < safetyCap
            guard isCurrentConnection(generation, configId: config.id) else { return }
            redisKeys = keys
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            presentError(error)
        }
    }
    
    /// 打开指定 Redis 键（设置查询并执行 GET）
    public func openRedisKey(_ key: String) async {
        queryText = "GET \(key)"
        await executeQuery()
    }

    /// 加载当前连接在侧边栏可见的对象分类（表/视图/例程…），结果写入 ``schemaCache``。
    /// MySQL/PG 首次连接后侧边栏不再为空，全靠这里填充。
    public func refreshSidebarObjects() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type != .redis else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let database: String? = config.type == .sqlite ? nil : config.database
        for kind in config.type.sidebarObjectKinds {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            // 这是用户可见的 Reload：必须绕过缓存重新读库，
            // 否则新建/删除表后对象树仍显示旧结构。
            _ = try? await schemaCache.objects(
                for: config,
                kind: kind,
                database: database,
                schema: nil,
                connection: connection,
                refresh: true
            )
        }
    }

    /// 统一打开一个数据库对象。表/视图进入分页浏览主区；其它对象暂不处理。
    /// `initialFilter` 用于引用行跳转等场景：打开即带过滤定位。
    public func openObject(_ object: DatabaseObject, initialFilter: TableFilter = .empty) async {
        guard let config = selectedConfig else { return }
        switch object.kind {
        case .table, .view, .materializedView:
            openTableObject = object
            selectedTableSchema = nil
            tableSchemaError = nil
            tablePage = 0
            tableRowCount = nil
            tableOrderBy = nil
            tableFilter = initialFilter
            showFilterPanel = initialFilter.isActive
            changeManager = nil
            pendingConflicts = []
            showConflictSheet = false
            cancelPendingWriteConfirmation()
            schemaChangeManager = nil
            // 兼容旧 UI（空状态判断等）
            if config.type == .sqlite { selectedSQLiteTable = object.name }
            await loadSelectedTableSchema()
            await loadTablePage()
        case .procedure, .function, .index, .trigger:
            await openDefinition(of: object)
        }
    }

    /// 打开只读定义面板（索引/触发器/例程）。DDL 缺失时展示空态而非静默无响应。
    public func openDefinition(of object: DatabaseObject) async {
        guard let config = selectedConfig else { return }
        let generation = connectionGeneration
        objectDefinition = ObjectDefinitionDisplay(id: object.id, object: object)
        guard let connection = await manager.getConnection(for: config.id) else {
            objectDefinition?.isLoading = false
            objectDefinition?.errorMessage = DatabaseError.connectionFailed("No active connection").localizedDescription
            return
        }
        guard connectionGeneration == generation else { return }
        do {
            let ddl = try await config.type.introspector.loadDDL(for: object, in: connection)
            guard connectionGeneration == generation else { return }
            objectDefinition?.ddl = ddl
            objectDefinition?.isLoading = false
        } catch {
            guard connectionGeneration == generation else { return }
            objectDefinition?.isLoading = false
            objectDefinition?.errorMessage = error.localizedDescription
        }
    }

    /// 关闭表浏览，回到 SQL 编辑器。
    public func closeTableBrowser() {
        openTableObject = nil
        selectedTableSchema = nil
        tableSchemaError = nil
        schemaChangeManager = nil
        tableRowCount = nil
        queryResult = nil
    }

    /// 从表浏览切到 SQL 编辑器，但保留当前 queryText/queryResult（让用户可基于浏览语句继续编辑）。
    public func switchToQueryEditor() {
        openTableObject = nil
        selectedTableSchema = nil
        tableSchemaError = nil
        schemaChangeManager = nil
    }

    /// 加载当前对象结构；刷新时绕过缓存重新读取数据库 catalog。
    public func loadSelectedTableSchema(refresh: Bool = false) async {
        let generation = connectionGeneration
        guard let config = selectedConfig, let object = openTableObject else { return }
        guard let connection = await manager.getConnection(for: config.id) else {
            tableSchemaError = "Not connected to database"
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }

        isLoadingTableSchema = true
        tableSchemaError = nil
        defer {
            // 连接已切换时由更新的加载负责收尾，旧任务不要提前关掉进度。
            if generation == connectionGeneration {
                isLoadingTableSchema = false
            }
        }

        do {
            let schema = try await schemaCache.tableSchema(
                for: object,
                config: config,
                connection: connection,
                refresh: refresh
            )
            guard isCurrentConnection(generation, configId: config.id),
                  openTableObject?.id == object.id else { return }
            selectedTableSchema = schema
            if schemaChangeManager?.hasChanges != true {
                schemaChangeManager = SchemaChangeManager(table: object, columns: schema.columns, indexes: schema.indexes)
            }
            if changeManager?.hasChanges != true {
                changeManager = TableChangeManager(table: object, schema: schema)
            }
        } catch {
            guard isCurrentConnection(generation, configId: config.id),
                  openTableObject?.id == object.id else { return }
            selectedTableSchema = nil
            changeManager = nil
            pendingConflicts = []
            showConflictSheet = false
            cancelPendingWriteConfirmation()
            schemaChangeManager = nil
            tableSchemaError = error.localizedDescription
        }
    }

    public var pendingSchemaChangeSQL: [String] {
        guard let config = selectedConfig else { return [] }
        return schemaChangeManager?.statements(for: config.type) ?? []
    }

    public func stageAddColumn(_ draft: NewTableColumnDraft) throws {
        try schemaChangeManager?.stageAdd(draft)
        objectWillChange.send()
    }

    public func stageRenameColumn(_ column: TableColumn, to name: String) throws {
        try schemaChangeManager?.stageRename(column, to: name)
        objectWillChange.send()
    }

    public func stageDropColumn(_ column: TableColumn) throws {
        try schemaChangeManager?.stageDrop(column)
        objectWillChange.send()
    }

    public func stageAddIndex(_ draft: NewTableIndexDraft) throws {
        try schemaChangeManager?.stageAddIndex(draft)
        objectWillChange.send()
    }

    public func stageDropIndex(_ index: TableIndex) throws {
        try schemaChangeManager?.stageDropIndex(index)
        objectWillChange.send()
    }

    public func removeSchemaChange(id: UUID) {
        schemaChangeManager?.remove(id: id)
        objectWillChange.send()
    }

    public func discardSchemaChanges() {
        schemaChangeManager?.discardAll()
        objectWillChange.send()
    }

    public func saveSchemaChanges() async {
        guard let config = selectedConfig,
              let manager = schemaChangeManager,
              manager.hasChanges else { return }
        guard let connection = await self.manager.getConnection(for: config.id) else {
            tableSchemaError = "Not connected to database"
            return
        }

        let statements = manager.statements(for: config.type)
        // 写权限闸门：DDL 属写操作；readOnly 拒绝（错误落到结构面板），confirmWrites 弹确认。
        switch await authorizeWrites(statements, type: config.type, kind: .schemaChange) {
        case .authorized: break
        case .cancelled: return
        case .blocked: tableSchemaError = readOnlySchemaErrorMessage; return
        }
        isLoadingTableSchema = true
        tableSchemaError = nil
        do {
            let transaction = try await connection.beginTransaction()
            do {
                for statement in statements {
                    _ = try await transaction.execute(statement, params: nil)
                }
                try await transaction.commit()
            } catch {
                try? await transaction.rollback()
                throw error
            }
            manager.discardAll()
            await loadSelectedTableSchema(refresh: true)
            await loadTablePage()
        } catch {
            tableSchemaError = error.localizedDescription
        }
        isLoadingTableSchema = false
    }

    /// 加载当前页数据（`SELECT * FROM ... [ORDER BY ...] LIMIT pageSize OFFSET page*pageSize`）。
    /// 页码超出范围时自动钳制到最后一页。
    public func loadTablePage() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, let table = openTableObject else { return }
        guard config.type.capabilities.supportsPagination else { return }
        guard let connection = await manager.getConnection(for: config.id) else {
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }

        let tableExpr = Self.qualifiedName(for: table, type: config.type)
        // SQLite 无主键表附带 rowid 别名，使完全相同的重复行也能被精确定位编辑。
        let selectList: String
        if config.type == .sqlite, table.kind == .table,
           let schema = selectedTableSchema, !schema.columns.contains(where: \.isPrimaryKey) {
            selectList = "rowid, *"
        } else {
            selectList = "*"
        }
        var sql = "SELECT \(selectList) FROM \(tableExpr)"
        var filterParams: [DatabaseValue]?
        if let whereClause = tableFilter.buildWhere(dialect: config.type, columns: selectedTableSchema?.columns ?? []) {
            sql += " WHERE \(whereClause.clause)"
            filterParams = whereClause.params
        }
        if let order = tableOrderBy {
            let col = Self.quoteIdentifier(order.column, for: config.type)
            sql += " ORDER BY \(col) \(order.ascending ? "ASC" : "DESC")"
        }
        let offset = tablePage * tablePageSize
        sql += " LIMIT \(tablePageSize) OFFSET \(offset)"

        isLoading = true
        errorMessage = nil
        do {
            let result = try await connection.query(sql, params: filterParams)
            guard isCurrentConnection(generation, configId: config.id),
                  openTableObject?.id == table.id else { return }
            queryResult = result
            // 如果本页空且不是首页，回退到上一页（例如删除后）
            if result.rows.isEmpty, tablePage > 0 {
                tablePage = max(0, tablePage - 1)
                await loadTablePage()
                isLoading = false
                return
            }
            queryText = sql  // 让 SQL 编辑器可见当前浏览语句
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            presentError(error)
        }
        isLoading = false

        // 后台拉取精确行数（不阻塞页面展示）
        if tableRowCount == nil {
            Task { await refreshTableRowCount() }
        }
    }

    /// 后台执行 `SELECT COUNT(*) FROM ...` 填充 ``tableRowCount``。
    public func refreshTableRowCount() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, let table = openTableObject else { return }
        guard config.type.capabilities.supportsPagination else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let tableExpr = Self.qualifiedName(for: table, type: config.type)
        var countSQL = "SELECT COUNT(*) FROM \(tableExpr)"
        var filterParams: [DatabaseValue]?
        if let whereClause = tableFilter.buildWhere(dialect: config.type, columns: selectedTableSchema?.columns ?? []) {
            countSQL += " WHERE \(whereClause.clause)"
            filterParams = whereClause.params
        }
        do {
            let result = try await connection.query(countSQL, params: filterParams)
            guard isCurrentConnection(generation, configId: config.id),
                  openTableObject?.id == table.id else { return }
            if let row = result.rows.first, let first = row.first {
                switch first {
                case .integer(let v): tableRowCount = v
                case .double(let v): tableRowCount = Int(v)
                case .string(let s): tableRowCount = Int(s)
                default: break
                }
            }
        } catch {
            // 行数查询失败不影响浏览
        }
    }

    public func nextPage() async {
        tablePage += 1
        await loadTablePage()
    }

    public func prevPage() async {
        guard tablePage > 0 else { return }
        tablePage -= 1
        await loadTablePage()
    }

    public func setPageSize(_ size: Int) async {
        tablePageSize = max(1, size)
        tablePage = 0
        await loadTablePage()
    }

    /// 点击表头排序：同一列循环 升→降→关。
    public func toggleSort(column: String) async {
        if let current = tableOrderBy, current.column == column {
            if current.ascending { tableOrderBy = (column, false) }
            else { tableOrderBy = nil }
        } else {
            tableOrderBy = (column, true)
        }
        tablePage = 0
        await loadTablePage()
    }

    // MARK: - 外键引用导航

    /// 列参与的外键（来自当前浏览表的结构）。
    public func foreignKey(for column: String) -> ForeignKey? {
        guard let schema = selectedTableSchema else { return nil }
        return ForeignKeySupport.foreignKey(for: column, in: schema)
    }

    /// 引用表候选项：按搜索词在引用表非二进制列上 LIKE，限量返回。
    public func fetchReferenceOptions(column: String, search: String) async throws -> [FKReferenceOption] {
        guard let config = selectedConfig,
              let fk = foreignKey(for: column),
              ForeignKeySupport.canPick(fk) else { return [] }
        guard let connection = await manager.getConnection(for: config.id) else {
            throw DatabaseError.connectionFailed("Not connected to a database")
        }
        let refObject = DatabaseObject(
            kind: .table,
            name: fk.referencesTable,
            database: openTableObject?.database,
            schema: openTableObject?.schema
        )
        let refSchema = try? await schemaCache.tableSchema(for: refObject, config: config, connection: connection)
        guard let query = ForeignKeySupport.referenceSearchSQL(
            fk,
            dialect: config.type,
            search: search,
            searchColumns: refSchema?.columns ?? []
        ) else { return [] }
        let result = try await connection.query(query.sql, params: query.params)
        return ForeignKeySupport.options(from: result, fk: fk)
    }

    /// 跳转到引用行：打开引用表并带上定位过滤（含已暂存编辑的显示值）。
    public func jumpToReference(column: String, rowValues: [DatabaseValue], columns: [String]) async {
        guard let config = selectedConfig, let fk = foreignKey(for: column) else { return }
        let values: [DatabaseValue]
        if let cm = changeManager {
            values = fk.columns.map { cm.displayedValue(column: $0, rowValues: rowValues, columns: columns) }
        } else {
            values = ForeignKeySupport.sourceValues(fk, rowValues: rowValues, columns: columns) ?? []
        }
        guard let filter = ForeignKeySupport.locateFilter(fk, values: values, dialect: config.type) else { return }
        let target = DatabaseObject(
            kind: .table,
            name: fk.referencesTable,
            database: openTableObject?.database,
            schema: openTableObject?.schema
        )
        await openObject(target, initialFilter: filter)
    }

    // MARK: - 表筛选

    /// 当前筛选的 WHERE 预览（供面板展示）；无过滤时为 nil。
    public var filterPreviewSQL: String? {
        guard let config = selectedConfig else { return nil }
        return tableFilter.previewWhere(dialect: config.type, columns: selectedTableSchema?.columns ?? [])
    }

    /// 应用当前筛选：回到首页、清空行数缓存（按过滤后重新计数）并加载。
    public func applyFilter() async {
        tablePage = 0
        tableRowCount = nil
        await loadTablePage()
    }

    /// 清空筛选并重新加载全量首页。
    public func clearFilter() async {
        tableFilter = .empty
        await applyFilter()
    }

    /// 追加一条空白筛选条件（默认对首列做等于过滤）。
    public func addFilterCondition() {
        let firstColumn = selectedTableSchema?.columns.first?.name ?? ""
        tableFilter.conditions.append(FilterCondition(column: firstColumn))
        objectWillChange.send()
    }

    /// 移除指定筛选条件。
    public func removeFilterCondition(_ id: UUID) {
        tableFilter.conditions.removeAll { $0.id == id }
        objectWillChange.send()
    }

    // MARK: - 数据编辑（变更跟踪）

    /// 暂存一个单元格修改到变更队列。
    public func stageCellChange(column: String, newValue: DatabaseValue, rowValues: [DatabaseValue], columns: [String]) {
        changeManager?.stageCellUpdate(column: column, newValue: newValue, rowValues: rowValues, columns: columns)
        // changeManager 自身的 objectWillChange 不会传导到观察本 viewModel 的视图，手动通知。
        objectWillChange.send()
    }

    /// 暂存新增行的某列值。
    public func stageInsertCell(insertId: UUID, column: String, value: DatabaseValue) {
        changeManager?.setInsertColumn(insertId: insertId, column: column, value: value)
        objectWillChange.send()
    }

    /// 暂存「置回数据库默认值」。
    ///
    /// MySQL/PG 直接生成 `col = DEFAULT`；SQLite 的 UPDATE 不支持 DEFAULT 关键字，
    /// 先以 `SELECT <默认表达式>` 求出具体值再按普通单元格修改暂存（无默认值则为 NULL）。
    public func stageCellDefault(column: String, rowValues: [DatabaseValue], columns: [String]) async {
        guard let cm = changeManager, let config = selectedConfig else { return }
        if config.type == .sqlite {
            var resolved: DatabaseValue = .null
            if let expr = cm.schema.columns.first(where: { $0.name == column })?.defaultValue,
               !expr.isEmpty,
               let connection = await manager.getConnection(for: config.id),
               let result = try? await connection.query("SELECT \(expr);", params: nil),
               let value = result.rows.first?.first {
                resolved = value
            }
            cm.stageCellUpdate(column: column, newValue: resolved, rowValues: rowValues, columns: columns)
        } else {
            cm.stageCellDefault(column: column, rowValues: rowValues, columns: columns)
        }
        objectWillChange.send()
    }

    /// 清除新增行某列的暂存值（恢复为使用数据库默认值）。
    public func clearPendingInsertColumn(insertId: UUID, column: String) {
        changeManager?.clearInsertColumn(insertId: insertId, column: column)
        objectWillChange.send()
    }

    /// 新增一个空行（返回临时 id）。
    @discardableResult
    public func addRow() -> UUID? {
        guard let id = changeManager?.addInsert() else { return nil }
        objectWillChange.send()
        return id
    }

    /// 移除一个未保存的新增行。
    public func removePendingInsert(_ insertId: UUID) {
        changeManager?.removeInsert(insertId)
        objectWillChange.send()
    }

    /// 切换某行的删除标记。
    public func toggleRowDeletion(rowValues: [DatabaseValue], columns: [String]) {
        changeManager?.toggleRowDeletion(rowValues: rowValues, columns: columns)
        objectWillChange.send()
    }

    public func undoChange() {
        changeManager?.undo()
        objectWillChange.send()
    }

    public func redoChange() {
        changeManager?.redo()
        objectWillChange.send()
    }

    /// 丢弃所有未保存的单元格修改。
    public func discardChanges() {
        changeManager?.discardAll()
        objectWillChange.send()
    }

    /// 当前待提交的 SQL 语句（DELETE → INSERT → UPDATE）。
    public var pendingChangeSQL: [String] {
        guard let config = selectedConfig, let cm = changeManager else { return [] }
        return cm.generatedAllStatements(for: config.type)
    }

    /// 提交变更：先做提交前乐观锁冲突扫描，有冲突则暂停并弹出解决面板；
    /// 无冲突则在事务中执行带 affected rows 验证的写入。
    public func saveChanges() async {
        guard let config = selectedConfig, let cm = changeManager, cm.hasChanges else { return }
        guard let connection = await manager.getConnection(for: config.id) else {
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            return
        }
        isLoading = true
        errorMessage = nil
        let conflicts: [RowConflict]
        do {
            conflicts = try await scanRowConflicts(cm: cm, connection: connection, type: config.type)
        } catch {
            isLoading = false
            presentError(error)
            return
        }
        isLoading = false
        if !conflicts.isEmpty {
            pendingConflicts = conflicts
            showConflictSheet = true
            return
        }
        await applyVerifiedWrites()
    }

    /// 提交前按定位重读每行当前快照，与编辑时的原始快照比对，收集冲突。
    private func scanRowConflicts(
        cm: TableChangeManager,
        connection: any DatabaseConnection,
        type: DatabaseType
    ) async throws -> [RowConflict] {
        var conflicts: [RowConflict] = []
        for target in cm.rowTargets {
            let result = try await connection.query(cm.reReadStatement(for: target, dialect: type), params: nil)
            if let conflict = detectRowConflict(target: target, result: result) {
                conflicts.append(conflict)
            }
        }
        return conflicts
    }

    /// 在事务中执行写计划：先验证每条 UPDATE/DELETE 的定位恰好命中一行
    /// （并复检内容冲突），再执行写入并验证 affected rows；任何不符即回滚并报告，
    /// 队列保留供重试/放弃。
    /// - Parameter overwriteConflicts: 用户已在冲突面板选择「覆盖」时跳过内容冲突复检
    ///   （仍验证命中行数；missing/ambiguous 无法覆盖，会照常中止）。
    public func applyVerifiedWrites(overwriteConflicts: Bool = false) async {
        guard let config = selectedConfig, let cm = changeManager, cm.hasChanges else { return }
        guard let connection = await manager.getConnection(for: config.id) else {
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            return
        }
        let plan = cm.writePlan(for: config.type)
        // 写权限闸门：变更队列提交（含冲突「覆盖/放弃」后的再次提交）统一在此拦截。
        switch await authorizeWrites(plan.map(\.sql), type: config.type, kind: .tableEdit) {
        case .authorized: break
        case .cancelled: return
        case .blocked: presentReadOnlyError(); return
        }
        isLoading = true
        errorMessage = nil
        do {
            let tx = try await connection.beginTransaction()
            do {
                // 第一遍：验证定位命中数，并在非覆盖模式下复检内容冲突。
                var reConflicts: [RowConflict] = []
                for write in plan {
                    guard let target = write.target else { continue }
                    let reread = try await connection.query(cm.reReadStatement(for: target, dialect: config.type), params: nil)
                    if reread.rows.isEmpty {
                        throw WriteVerificationError(sql: write.sql, expected: 1, actual: 0, reason: .missingRow)
                    }
                    if reread.rows.count > 1 {
                        throw WriteVerificationError(sql: write.sql, expected: 1, actual: reread.rows.count, reason: .ambiguousRow)
                    }
                    if !overwriteConflicts, let conflict = detectRowConflict(target: target, result: reread) {
                        reConflicts.append(conflict)
                    }
                }
                if !reConflicts.isEmpty {
                    try await tx.rollback()
                    pendingConflicts = reConflicts
                    showConflictSheet = true
                    isLoading = false
                    return
                }
                // 第二遍：执行写入并验证 affected rows。
                for write in plan {
                    let affected = try await tx.execute(write.sql, params: nil)
                    if let target = write.target {
                        try verifyAffectedRows(
                            actual: affected,
                            operation: target.isDelete ? .delete : .update,
                            dialect: config.type,
                            sql: write.sql
                        )
                    } else if affected != 1 {
                        throw WriteVerificationError(sql: write.sql, expected: 1, actual: affected, reason: .affectedMismatch)
                    }
                }
                try await tx.commit()
            } catch {
                try? await tx.rollback()
                throw error
            }
            cm.discardAll()
            pendingConflicts = []
            objectWillChange.send()
            await loadTablePage()
        } catch {
            presentError(error)
        }
        isLoading = false
    }

    // MARK: - 冲突解决

    /// 「覆盖」：忽略内容冲突，按定位强制写入（missing/ambiguous 仍会在验证时中止）。
    public func overwriteConflictsAndSave() async {
        showConflictSheet = false
        await applyVerifiedWrites(overwriteConflicts: true)
    }

    /// 「放弃冲突行」：移除冲突行的待提交变更，保存其余变更。
    public func discardConflictedRowsAndSave() async {
        guard let cm = changeManager else { return }
        for conflict in pendingConflicts {
            cm.removeRowChanges(forKey: conflict.id)
        }
        pendingConflicts = []
        showConflictSheet = false
        objectWillChange.send()
        await saveChanges()
    }

    /// 「取消」：关闭面板，保留变更队列，不写库。
    public func cancelConflictResolution() {
        pendingConflicts = []
        showConflictSheet = false
    }

    // MARK: - 写权限闸门（连接级安全模式）

    /// 写确认请求的展示模型。
    public struct WriteConfirmationRequest: Identifiable, Sendable {
        public let id = UUID()
        public let kind: WriteOperationKind
        public let writeCount: Int
        public let previewSQL: String?
    }

    /// 对一批待执行语句应用写闸门（VM 层 UX）。
    ///
    /// 仅对写语句生效：off 放行；readOnly 返回 ``WriteAuthorization/blocked``（调用方给出本地化错误）；
    /// confirmWrites 弹确认并挂起，用户确认返回 authorized、取消返回 cancelled。
    /// 驱动层另有 readOnly 硬保证（``SafeModeConnection``），此处负责友好提示与确认流程。
    func authorizeWrites(_ sqls: [String], type: DatabaseType, kind: WriteOperationKind) async -> WriteAuthorization {
        let writes = sqls.filter { WriteGate.isWriteStatement($0, type: type) }
        guard !writes.isEmpty, let config = selectedConfig else { return .authorized }
        switch WriteGate.decision(safeMode: config.safeMode, isWrite: true) {
        case .proceed:
            return .authorized
        case .blocked:
            return .blocked
        case .requiresConfirmation:
            let approved = await requestWriteConfirmation(kind: kind, writeCount: writes.count, preview: writes.first)
            return approved ? .authorized : .cancelled
        }
    }

    /// readOnly 拒绝写操作时的本地化错误（归类为权限不足，恢复动作「编辑连接」可改安全模式）。
    func presentReadOnlyError() {
        let message = pluginLocalization.string("This connection is read-only. Writes are blocked. Edit the connection to change its safe mode.")
        classifiedError = ClassifiedDatabaseError(category: .permissionDenied, detail: message)
        errorMessage = message
    }

    /// readOnly 拒绝写操作时用于结构变更面板的本地化错误文案。
    var readOnlySchemaErrorMessage: String {
        pluginLocalization.string("This connection is read-only. Structure changes are blocked. Edit the connection to change its safe mode.")
    }

    private func requestWriteConfirmation(kind: WriteOperationKind, writeCount: Int, preview: String?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            writeConfirmationContinuation = continuation
            writeConfirmation = WriteConfirmationRequest(kind: kind, writeCount: writeCount, previewSQL: preview)
        }
    }

    /// 用户对写确认弹窗的决定：true 继续执行，false 取消。续体只消费一次，重复调用安全。
    public func resolveWriteConfirmation(_ approved: Bool) {
        writeConfirmation = nil
        let continuation = writeConfirmationContinuation
        writeConfirmationContinuation = nil
        continuation?.resume(returning: approved)
    }

    /// 连接切换/断开时取消仍在挂起的写确认，避免续体泄漏导致写流程永久挂起。
    private func cancelPendingWriteConfirmation() {
        guard writeConfirmationContinuation != nil else { return }
        resolveWriteConfirmation(false)
    }

    /// 按方言引用单个标识符（SQLite/PG 用双引号，MySQL 用反引号）。
    public nonisolated static func quoteIdentifier(_ name: String, for type: DatabaseType) -> String {
        guard let quote = type.capabilities.identifierQuoteCharacter else { return name }
        let escaped = name.replacingOccurrences(of: String(quote), with: String(quote) + String(quote))
        return "\(quote)\(escaped)\(quote)"
    }

    /// 构造带库/schema 限定的表名（MySQL: `db`.`t`；PG: "schema"."t"；SQLite: "t"）。
    public nonisolated static func qualifiedName(for object: DatabaseObject, type: DatabaseType) -> String {
        func q(_ s: String) -> String { quoteIdentifier(s, for: type) }
        switch type {
        case .mysql:
            if let db = object.database, !db.isEmpty { return "\(q(db)).\(q(object.name))" }
            return q(object.name)
        case .postgresql:
            if let schema = object.schema, !schema.isEmpty { return "\(q(schema)).\(q(object.name))" }
            return q(object.name)
        case .sqlite, .redis:
            return q(object.name)
        }
    }
    
    /// 加载 SQLite 表列表
    public func loadSQLiteTables() async {
        guard let config = selectedConfig, config.type == .sqlite else { return }
        let configID = config.id
        guard let connection = await manager.getConnection(for: configID) else {
            // 连接建立失败时清掉旧表，避免继续显示上一个库的表。
            guard selectedConfig?.id == configID else { return }
            sqliteTables = []
            selectedSQLiteTable = nil
            return
        }
        do {
            let result = try await connection.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;", params: nil)
            let names = result.rows.compactMap { row -> String? in
                if let first = row.first {
                    switch first {
                    case .string(let s): return s
                    default: return first.description
                    }
                }
                return nil
            }
            // 查询期间切换了数据库：结果属于旧连接，不能写进当前详情页。
            guard selectedConfig?.id == configID else { return }
            sqliteTables = names
            if let selectedSQLiteTable, !names.contains(selectedSQLiteTable) {
                self.selectedSQLiteTable = nil
            }
        } catch {
            guard selectedConfig?.id == configID else { return }
            presentError(error)
        }
    }
    
    /// 打开指定 SQLite 表
    public func openSQLiteTable(_ name: String) async {
        selectedSQLiteTable = name
        queryText = "SELECT * FROM \(quotedSQLiteIdentifier(name)) LIMIT 50;"
        await executeQuery()
    }

    private func quotedSQLiteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    
    private func initDemoData(configId: UUID) async throws {
        guard let connection = await manager.getConnection(for: configId) else { return }
        _ = try await connection.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)", params: nil)
        _ = try await connection.execute("INSERT INTO users (name, email) VALUES (?, ?)", params: [.string("Alice"), .string("alice@example.com")])
        _ = try await connection.execute("INSERT INTO users (name, email) VALUES (?, ?)", params: [.string("Bob"), .string("bob@example.com")])
    }
}
