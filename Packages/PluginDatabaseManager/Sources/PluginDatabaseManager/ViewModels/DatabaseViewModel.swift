import ProviderEditor
import Foundation
import LumiLoggingKit
import Combine
import CoreGraphics
import AppKit
import UniformTypeIdentifiers

@MainActor
public class DatabaseViewModel: ObservableObject, SuperLog {
    public nonisolated static let emoji = "🗄️"
    @Published var configs: [DatabaseConfig] = []
    @Published var selectedConfig: DatabaseConfig?
    @Published var queryText: String = "SELECT * FROM sqlite_master;" {
        didSet { scheduleWorkspacePersist(); refreshParameterNames(); refreshSQLDiagnostics() }
    }
    @Published var queryResult: QueryResult?
    @Published var errorMessage: String? {
        didSet { if errorMessage == nil { classifiedError = nil } }
    }
    /// 当前错误的语义分类（本地化标题 + 恢复动作），与 ``errorMessage`` 同步。
    @Published public private(set) var classifiedError: ClassifiedDatabaseError?
    /// 待编辑的连接；错误恢复动作「编辑连接」会置位并弹出表单。
    @Published public var configPendingEdit: DatabaseConfig?
    /// 连接表单是否正在展示。密码询问/命令确认闸门据此决定由表单还是工作区呈现，
    /// 避免表单 sheet 与工作区 sheet 同时呈现同一请求而冲突。
    @Published public var isConnectionFormPresented = false
    /// 连接级 startup SQL 执行失败的非阻塞提示（连接本身仍成功）。nil 表示无提示。
    /// 与 ``errorMessage`` 区分：后者意味着查询/连接失败，前者仅是会话引导脚本未跑通。
    @Published public private(set) var startupSQLNotice: String?
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var redisKeys: [String] = []
    /// 命名空间键树（由 ``redisKeys`` 按分隔符聚合），侧边栏类型化浏览的数据源。
    @Published public private(set) var redisKeyTree: [RedisKeyTreeNode] = []
    /// 键名分隔符（默认 `:`）；改变后重建键树。
    @Published public var redisKeySeparator: String = ":" {
        didSet { rebuildRedisKeyTree() }
    }
    /// SCAN 游标分页状态：当前游标、是否还有更多键、是否正在扫描。
    @Published public private(set) var redisScanCursor: String = "0"
    @Published public private(set) var redisHasMoreKeys: Bool = false
    @Published public private(set) var isLoadingRedisKeys: Bool = false
    /// 当前打开的键元信息（类型 + TTL）与类型化值；nil 表示未打开键详情。
    @Published public private(set) var selectedRedisKey: RedisKeyInfo?
    @Published public private(set) var selectedRedisValue: RedisKeyValue?
    @Published public private(set) var isLoadingRedisValue: Bool = false
    @Published public private(set) var redisValueError: String?
    @Published var sqliteTables: [String] = []
    @Published var selectedSQLiteTable: String?
    /// 侧边栏当前展示的内容：数据浏览（Tables/Keys）或连接列表。
    @Published public var sidebarMode: DatabaseSidebarMode = .browser

    /// 当前活动的库/schema 上下文。可与持久化的 ``DatabaseConfig/database`` 不同：
    /// 用户在对象树切换库（MySQL/PG，重连）或 schema（PG，SET search_path）后在此反映，
    /// 侧边栏对象树与查询限定都跟随它，而不改动已保存的连接配置。
    @Published public private(set) var activeDatabase: String?
    @Published public private(set) var activeSchema: String?
    /// 服务器上可切换的库列表（MySQL/PG）与当前库下的 schema 列表（PG）。
    @Published public private(set) var availableDatabases: [String] = []
    @Published public private(set) var availableSchemas: [String] = []
    @Published public private(set) var isLoadingSchemaContext: Bool = false

    /// 结构元数据缓存（表/列/索引等），侧边栏对象树与结构 Tab 共用。
    public let schemaCache = SchemaCacheService()

    /// 右侧 Inspector 是否可见（结构详情 / ER 图 / EXPLAIN 等将放在这里）。
    @Published public var inspectorVisible: Bool = false

    /// 只读 ER 图：当前库/schema 的表关系图（节点+边+布局）。
    @Published private(set) var erDiagram: ERDiagram?
    @Published public private(set) var erDiagramError: String?
    @Published public private(set) var isLoadingERDiagram: Bool = false
    /// ER 图面板是否展示。
    @Published public var isERDiagramPresented: Bool = false

    /// EXPLAIN 计划树（当前编辑器语句的执行计划）。
    @Published private(set) var queryPlan: QueryPlan?
    @Published public private(set) var queryPlanError: String?
    @Published public private(set) var isLoadingPlan: Bool = false
    /// EXPLAIN 面板是否展示。
    @Published public var isQueryPlanPresented: Bool = false

    /// 建表面板是否展示。
    @Published public var isCreateTablePresented: Bool = false
    @Published public private(set) var createTableError: String?
    @Published public private(set) var isCreatingTable: Bool = false
    @Published public var isImportDataPresented: Bool = false
    @Published public private(set) var importFormat: ImportFileFormat?
    @Published public private(set) var importSourceColumns: [String] = []
    @Published public private(set) var importPreviewRows: [[ImportCell]] = []
    @Published public private(set) var importInferredTypes: [ImportColumnType] = []
    @Published public var importHasHeader: Bool = true
    @Published public private(set) var isImporting: Bool = false
    @Published public private(set) var importProgress: Double = 0
    @Published public private(set) var importedRowCount: Int = 0
    @Published public private(set) var importBadRows: [ImportBadRow] = []
    @Published public private(set) var importError: String?
    @Published public private(set) var importCompleted: Bool = false
    private var importFileURL: URL?
    private var importTask: Task<Void, Never>?

    // MARK: - 数据导出状态

    @Published public var isExportPresented: Bool = false
    @Published public var exportFormat: ExportFormat = .csv
    @Published public var exportRange: ExportRowRange = .currentPage
    @Published public private(set) var isExporting: Bool = false
    @Published public private(set) var exportProgress: Double = 0
    @Published public private(set) var exportedRowCount: Int = 0
    @Published public private(set) var exportError: String?
    @Published public private(set) var exportCompleted: Bool = false
    @Published public private(set) var exportPresets: [ExportPreset] = []
    private var exportTask: Task<Void, Never>?

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
    /// 表的总行数（后台异步填充；nil 表示未知）。无筛选时优先引擎估算。
    @Published public var tableRowCount: Int? {
        didSet { if tableRowCount == nil { tableRowCountIsApproximate = false } }
    }
    /// ``tableRowCount`` 是否为引擎估算值（true 时 UI 显示「约」并提供精确计数入口）。
    @Published public var tableRowCountIsApproximate: Bool = false
    /// 服务端排序（列名 + 方向）；nil 表示不排序。
    @Published public var tableOrderBy: (column: String, ascending: Bool)?
    /// 深翻页改用 keyset（游标）分页：按单一主键排序时用 `WHERE key > last`
    /// 替代 OFFSET，避免深页线性扫描。设置持久化到 UserDefaults。
    @Published public var useKeysetPagination: Bool = UserDefaults.standard.bool(forKey: "DatabaseManager.useKeysetPagination") {
        didSet { UserDefaults.standard.set(useKeysetPagination, forKey: "DatabaseManager.useKeysetPagination") }
    }
    /// 当前 keyset 游标（nil 表示首页）；仅在 keyset 模式下使用。
    private var keysetCursor: KeysetCursor?
    /// 游标历史栈，支持 keyset 模式回退上一页。
    private var keysetHistory: [KeysetCursor?] = []
    /// 当前表的用户列宽覆盖（按列名）；持久化到 UserDefaults。
    @Published public private(set) var gridColumnWidths: [String: CGFloat] = [:]
    /// 当前表的用户列顺序（列名序列）；空表示自然顺序。持久化到 UserDefaults。
    @Published public private(set) var gridColumnOrder: [String] = []
    /// 当前表的服务端筛选（条件组合或 raw WHERE）；空表示不过滤。
    @Published public var tableFilter: TableFilter = .empty
    /// 是否展开筛选面板。
    @Published public var showFilterPanel: Bool = false
    /// NULL 单元格显示为 ⟨NULL⟩（否则显示 NULL）；设置持久化到 UserDefaults。
    @Published public var useNullSymbol: Bool = UserDefaults.standard.bool(forKey: "DatabaseManager.useNullSymbol") {
        didSet { UserDefaults.standard.set(useNullSymbol, forKey: "DatabaseManager.useNullSymbol") }
    }

    // MARK: - 网格查找

    /// 是否展开网格查找条（⌘F）。
    @Published public var gridFindVisible: Bool = false
    /// 查找词。
    @Published public var gridFindText: String = ""
    /// 查找范围：当前页（客户端匹配）或全量（服务端 LIKE）。
    @Published public var gridFindScope: GridFindScope = .currentPage
    /// 当前页内匹配的单元格位置（行优先）；供网格高亮与导航。
    @Published public private(set) var gridFindMatches: [GridFind.CellPosition] = []
    /// 当前活动匹配在 ``gridFindMatches`` 中的索引。
    @Published public private(set) var gridFindMatchIndex: Int = 0
    /// 生效的全量服务端查找词（nil 表示无服务端查找）；与筛选 AND 组合。
    private var gridSearchTerm: String?

    /// 当前活动匹配位置（无匹配时 nil）。
    public var activeGridFindMatch: GridFind.CellPosition? {
        guard gridFindMatchIndex >= 0, gridFindMatchIndex < gridFindMatches.count else { return nil }
        return gridFindMatches[gridFindMatchIndex]
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

    /// 密码询问请求（askEveryTime 来源）；非 nil 时弹出密码输入面板，连接流程挂起等待输入。
    /// 密码仅存内存、随连接配置副本下发，绝不写回已保存配置或落盘。
    @Published public private(set) var passwordPrompt: PasswordPromptRequest?
    /// 密码询问的挂起续体；用户输入（nil 表示取消）后恢复连接流程。
    private var passwordPromptContinuation: CheckedContinuation<String?, Never>?

    /// 命令确认请求（command 来源）；非 nil 时弹出确认对话框，连接流程挂起等待用户批准。
    /// 本机执行命令取密码前必须经此闸门；命令输出绝不写入日志。
    @Published public private(set) var commandConfirmation: CommandConfirmationRequest?
    /// 命令确认的挂起续体；用户决定后恢复连接流程。
    private var commandConfirmationContinuation: CheckedContinuation<Bool, Never>?

    /// 密码来源解析器（环境表/文件读取/命令执行依赖可注入，便于离线测试）。
    var passwordResolver = PasswordSourceResolver()

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
    /// 编辑器当前选区在 ``queryText`` 中的 UTF-16 范围；length 为 0 表示无选区（仅光标）。
    @Published public var editorSelectionRange: NSRange = NSRange(location: NSNotFound, length: 0)
    /// 命名参数面板绑定值（按参数名）；仅内存保存，不落盘（可能含敏感值）。
    @Published public var parameterBindings: [String: QueryParameterBinding] = [:]
    /// 当前编辑器文本中出现的命名参数（去重、首次出现顺序），驱动参数面板。
    @Published public private(set) var activeParameterNames: [String] = []
    /// 当前编辑器文本的结构化诊断（括号/引号/注释失配、形近与不可见字符），驱动诊断条。
    @Published public private(set) var sqlDiagnostics: [SQLStructuralDiagnostic] = []

    // MARK: - 编辑器查询行数上限与增量加载

    /// 编辑器查询的默认行数上限；用户 SQL 自带 LIMIT 时不覆盖。0 表示不限制。
    @Published public var queryRowLimit: Int = 1000
    /// 当前编辑器结果的基础 SQL（去尾分号）；nil 表示不可增量加载。
    @Published public private(set) var editorBaseSQL: String?
    /// 当前结果是否还有更多行可加载（注入了 LIMIT 且上一页取满）。
    @Published public private(set) var editorHasMore: Bool = false
    /// 已取回的行数，作为下一次加载的 OFFSET。
    @Published public private(set) var editorFetchedRows: Int = 0
    /// 当前编辑器结果基础 SQL 的绑定参数（命名参数改写后）；增量加载复用。
    @Published public private(set) var editorBaseParams: [DatabaseValue]?
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

    /// 对象定义编辑草稿（nil 表示只读查看）；保存时按引擎决定 DROP+CREATE 或 CREATE OR REPLACE。
    @Published public var objectDefinitionDraft: String?
    @Published public private(set) var isSavingDefinition: Bool = false
    @Published public private(set) var definitionSaveError: String?

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
    /// 历史保留期（天，0 表示永久保留）。
    @Published public var historyRetentionDays: Int = 0

    private let historyStore: QueryHistoryStore

    /// 收藏查询（按连接名组织，UI 通过此状态渲染）。
    @Published public private(set) var savedQueries: [SavedQuery] = []
    /// 代码片段（全局共享，插入编辑器时展开占位符）。
    @Published public private(set) var snippets: [Snippet] = []

    private let savedQueryStore: SavedQueryStore

    /// 全局偏好设置；任何改动经 didSet 持久化到工作区 UserDefaults。
    @Published public var settings: DatabaseSettings = DatabaseSettings() {
        didSet {
            settingsStore.save(settings)
            DatabaseManagerPluginSupport.debugLog.setDebugEnabled(settings.debugLoggingEnabled)
        }
    }

    private let settingsStore: DatabaseSettingsStore

    /// 新建连接的默认安全模式（来自全局设置）。
    public var defaultSafeMode: ConnectionSafeMode { settings.safeMode }

    /// 当前连接的收藏查询（按创建时间倒序）。
    public var currentConnectionSavedQueries: [SavedQuery] {
        let configName = selectedConfig?.name ?? ""
        return savedQueries
            .filter { $0.configName == configName }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func toggleInspector() {
        inspectorVisible.toggle()
    }

    private let manager: DatabaseManagerCore

    /// 宿主注入的嵌入式编辑器能力（语法高亮）；nil 时 View 退回 TextEditor。
    @Published public var embeddedEditorProvider: (any EditorEmbeddedEditorProviding)?
    /// SQL schema 感知补全 Provider；注入嵌入式编辑器选项，由宿主桥接到补全弹层。
    public lazy var sqlCompletionProvider: SQLCompletionProvider = SQLCompletionProvider(
        manager: manager,
        schemaCache: schemaCache,
        configResolver: { [weak self] in self?.selectedConfig }
    )
    /// 多标签查询工作区：标签序列/活动标签/最近关闭/会话持久化。
    /// 首次访问时若从磁盘恢复则载入活动标签，否则用当前编辑器默认文本播种。
    public lazy var workspace: QueryWorkspaceStore = {
        let store = QueryWorkspaceStore(defaults: workspaceDefaults)
        if store.loadedFromDisk {
            applyTab(store.activeTab)
        } else {
            store.updateActive { $0.text = queryText; $0.savedText = queryText }
        }
        return store
    }()
    /// 待确认关闭的脏标签；非 nil 时弹出关闭确认。
    @Published public var pendingCloseTabID: UUID?
    /// 正在执行的标签 id（供标签条显示进度）；nil 表示空闲。
    @Published public private(set) var runningTabID: UUID?
    /// 正在把快照载入实时状态：抑制期间的持久化调度，避免恢复触发写盘。
    private var isRestoringTab = false
    /// 文本编辑后的防抖持久化任务。
    private var workspacePersistTask: Task<Void, Never>?
    /// 工作区持久化所用的 UserDefaults（测试可注入独立 suite 避免串扰）。
    private let workspaceDefaults: UserDefaults
    /// 活动标签 SQL 文件的外部变更冲突（驱动 Reload / Save As 横幅）；nil 表示无冲突。
    @Published public private(set) var sqlFileConflict: SQLFileConflict?
    /// SQL 文件外部变更轮询任务（仅连接且活动标签关联文件时实际探测）。
    private var fileWatchTask: Task<Void, Never>?
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
    public init(loadSavedConfigs: Bool, manager: DatabaseManagerCore = .shared, workspaceDefaults: UserDefaults = .standard, historyStore: QueryHistoryStore? = nil) {
        self.manager = manager
        self.workspaceDefaults = workspaceDefaults
        self.historyStore = historyStore ?? .shared
        self.historyRetentionDays = max(0, workspaceDefaults.integer(forKey: "DatabaseManager.historyRetentionDays"))
        self.savedQueryStore = SavedQueryStore(defaults: workspaceDefaults)
        self.savedQueries = savedQueryStore.loadQueries()
        self.snippets = savedQueryStore.loadSnippets()
        self.settingsStore = DatabaseSettingsStore(defaults: workspaceDefaults)
        self.settings = settingsStore.load()
        DatabaseManagerPluginSupport.debugLog.setDebugEnabled(settings.debugLoggingEnabled)
        Task {
            await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        }
        DatabaseManagerPluginSupport.debugLog.debug("\(Self.t)初始化数据库视图模型")
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
        // 尽早初始化工作区：恢复会话或用默认编辑器文本播种，避免连接流程中懒加载竞态。
        _ = workspace
        startFileWatch()
    }

    deinit {
        heartbeatTask?.cancel()
        fileWatchTask?.cancel()
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

    /// 批量导入连接：跳过与现有配置同名+同引擎+同主机+同库的重复项（含批次内重复），
    /// 一次性保存。返回实际新增数量。导入只还原非秘密字段，密码/SSH 由用户后续补填。
    @discardableResult
    public func importConfigs(_ imported: [DatabaseConfig]) -> Int {
        var added = 0
        for config in imported {
            let isDuplicate = configs.contains {
                $0.name == config.name && $0.type == config.type
                    && $0.host == config.host && $0.database == config.database
            }
            if isDuplicate { continue }
            configs.append(config)
            added += 1
            Task { await DatabaseAgentConnectionRegistry.shared.upsert(config) }
        }
        if added > 0 {
            DatabaseConnectionStore.saveConfigs(configs)
        }
        return added
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
        let generation = connectionGeneration
        let probeConfig = try await resolvedConnectConfig(for: config, generation: generation)
        guard connectionGeneration == generation else { throw DatabaseError.cancelled }
        try await manager.probe(config: probeConfig)
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
        cancelPendingPasswordRequests()
        DatabaseManagerPluginSupport.debugLog.debug("\(self.t)连接数据库: \(config.name)")
        isLoading = true
        errorMessage = nil
        startupSQLNotice = nil
        do {
            // 解析密码来源（file/env/command/每次询问）；command 与 askEveryTime 经用户确认闸门。
            // 解析出的密码只进连接副本与 Agent 注册表，selectedConfig 仍保留原始来源配置（不落盘明文）。
            let connectConfig = try await resolvedConnectConfig(for: config, generation: generation)
            guard connectionGeneration == generation else { return }
            await DatabaseAgentConnectionRegistry.shared.upsert(connectConfig)
            guard connectionGeneration == generation else { return }
            _ = try await manager.connect(config: connectConfig)
            // 连接期间用户已切换/断开：回收刚建立的连接，不再写任何状态。
            guard connectionGeneration == generation else {
                await manager.disconnect(configId: config.id)
                return
            }
            let previousConfigId = selectedConfig?.id
            selectedConfig = config
            connectedConfigId = config.id
            isConnected = true
            queryRowLimit = settings.defaultQueryRowLimit > 0
                ? settings.defaultQueryRowLimit
                : config.type.capabilities.defaultQueryLimit
            resetEditorPaging()
            queryResult = nil
            workspace.clearAllResults()
            clearRedisBrowserState()
            resetSchemaContext()
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

            // 连接级 startup SQL：用户为该连接编写的会话引导脚本，连接成功后执行。
            // 放在库/schema 上下文与对象树预加载之前，使脚本建立的会话状态/对象能被后续读取反映。
            await runStartupSQL(for: config, generation: generation)
            guard connectionGeneration == generation else { return }

            // 先确立库/schema 上下文（MySQL/PG 多库、PG 多 schema），再据此预加载对象树。
            await loadSchemaContext()
            // 为侧边栏对象树预加载可见分类（表/视图/例程），MySQL/PG 由此不再空白。
            await refreshSidebarObjects()

            guard connectionGeneration == generation else { return }

            // 默认/保留文本与已清空的结果同步进活动标签快照。
            syncActiveSnapshot()

            didAttemptAutoReconnect = false
            startHeartbeat()

            if let previousConfigId, previousConfigId != config.id {
                await manager.disconnect(configId: previousConfigId)
            }

            DatabaseManagerPluginSupport.debugLog.debug("\(self.t)数据库连接成功: \(config.name)")
        } catch {
            guard connectionGeneration == generation else { return }
            DatabaseManagerPluginSupport.debugLog.error("\(self.t)数据库连接失败: \(error.localizedDescription)")
            // 重连失败时旧连接已不可用，必须落回未连接态，避免界面误判仍在线。
            isConnected = false
            stopHeartbeat()
            presentError(error)
        }
        isLoading = false
    }

    /// 执行连接级 startup SQL（会话引导脚本）。这是用户为该连接显式编写的初始化语句，
    /// 连接成功后经连接直接下发（不经交互式写闸门），与 schema 切换的 `SET search_path` 同理。
    /// 任一语句失败即停止并置 ``startupSQLNotice``，但**不** teardown 连接——连接本身已成功。
    /// SQL 引擎按 ``SQLStatementParser/split(_:)`` 切分；Redis 按换行逐条命令执行。
    private func runStartupSQL(for config: DatabaseConfig, generation: Int) async {
        guard let sql = config.startupSQL, !sql.isEmpty else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let statements: [String]
        if config.type == .redis {
            statements = sql.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            statements = SQLStatementParser.split(sql)
        }
        for statement in statements {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            do {
                _ = try await connection.query(statement, params: nil)
            } catch {
                guard isCurrentConnection(generation, configId: config.id) else { return }
                startupSQLNotice = String(format: pluginLocalization.string("Startup SQL failed: %@"), error.localizedDescription)
                return
            }
        }
    }

    /// 关闭 startup SQL 失败提示（界面横幅的关闭按钮调用）。
    public func dismissStartupSQLNotice() {
        startupSQLNotice = nil
    }

    public func disconnect() async {
        guard let config = selectedConfig else { return }
        stopHeartbeat()
        let generation = beginConnectionGeneration()
        DatabaseManagerPluginSupport.debugLog.debug("\(self.t)断开数据库连接: \(config.name)")
        await manager.disconnect(configId: config.id)
        // 断开等待期间又建立了新连接：不要清掉新连接的状态。
        guard connectionGeneration == generation else { return }
        isConnected = false
        isLoading = false
        selectedConfig = nil
        connectedConfigId = nil
        startupSQLNotice = nil
        queryResult = nil
        multiExecutions = []
        selectedExecutionIndex = 0
        lastBatchRolledBack = false
        resetEditorPaging()
        workspace.clearAllResults()
        syncActiveSnapshot()
        clearRedisBrowserState()
        resetSchemaContext()
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
        cancelPendingPasswordRequests()
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

    /// ⌘⇧F：格式化选区（有有效选区时）或整段编辑器文本。
    ///
    /// 仅调整空白与关键字大小写，不改变语义；格式化结果写回 ``queryText``，
    /// 经工作区防抖持久化同步到活动标签。
    public func formatDocumentOrSelection() {
        let options = settings.formatterOptions
        let ns = queryText as NSString
        let selection = editorSelectionRange
        if selection.location != NSNotFound, selection.length > 0, NSMaxRange(selection) <= ns.length {
            let original = ns.substring(with: selection)
            let formatted = SQLFormatterService.format(original, options: options)
            guard formatted != original else { return }
            queryText = ns.replacingCharacters(in: selection, with: formatted)
        } else {
            let formatted = SQLFormatterService.format(queryText, options: options)
            guard formatted != queryText else { return }
            queryText = formatted
        }
    }

    /// 重新提取当前文本的命名参数，驱动参数面板。
    ///
    /// 保留已录入的绑定值（含当前未出现的名字），仅为新名字补默认值；
    /// Redis 命令不是 SQL，不展示参数面板。
    private func refreshParameterNames() {
        guard selectedConfig?.type != .redis else {
            activeParameterNames = []
            return
        }
        let names = SQLNamedParameters.names(in: queryText)
        for name in names where parameterBindings[name] == nil {
            parameterBindings[name] = QueryParameterBinding()
        }
        activeParameterNames = names
    }

    /// 把一条语句的 `:name` 解析为引擎位置占位符 + 绑定值。
    ///
    /// 缺值或类型非法时抛错（执行前拦截）；Redis 与无参数语句原样返回、params 为 nil，
    /// 保持既有行为。MySQL/SQLite 用 `?`、PostgreSQL 用 `$n`，均按出现顺序绑定。
    private func resolveParameters(_ sql: String, type: DatabaseType) throws -> (sql: String, params: [DatabaseValue]?) {
        guard type != .redis else { return (sql, nil) }
        let names = SQLNamedParameters.names(in: sql)
        guard !names.isEmpty else { return (sql, nil) }
        var values: [String: DatabaseValue] = [:]
        for name in names {
            let binding = parameterBindings[name] ?? QueryParameterBinding()
            guard binding.isSatisfied else {
                throw DatabaseError.queryFailed("\(pluginLocalization.string("Missing value for parameter")) :\(name)")
            }
            guard let value = binding.databaseValue else {
                throw DatabaseError.queryFailed("\(pluginLocalization.string("Invalid value for parameter")) :\(name)")
            }
            values[name] = value
        }
        let placeholder: (Int) -> String = type == .postgresql ? { "$\($0 + 1)" } : { _ in "?" }
        let rewritten = SQLNamedParameters.rewrite(sql, placeholder: placeholder) { values[$0]! }
        return (rewritten.sql, rewritten.params)
    }

    /// `isRetry` 为 true 时不再触发断线重连，避免重连-重试无限循环。
    /// `sqlOverride` 非 nil 时执行该语句而非整段 ``queryText``（光标单句执行）。
    private func executeQuery(isRetry: Bool, sqlOverride: String?) async {
        let generation = connectionGeneration
        let origin = workspace.activeTabID
        let sql = sqlOverride ?? queryText
        guard let config = selectedConfig else {
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            DatabaseManagerPluginSupport.debugLog.error("\(self.t)执行查询失败: 未连接到数据库")
            return
        }
        guard let connection = await manager.getConnection(for: config.id) else {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            DatabaseManagerPluginSupport.debugLog.error("\(self.t)执行查询失败: 未连接到数据库")
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

        // 命名参数解析：缺值/非法即拦截，不进入执行。
        let resolved: (sql: String, params: [DatabaseValue]?)
        do {
            resolved = try resolveParameters(sql, type: config.type)
        } catch {
            presentError(error)
            return
        }

        DatabaseManagerPluginSupport.debugLog.debug("\(self.t)执行查询: \(sql.prefix(50))...")

        isLoading = true
        runningTabID = origin
        let sequence = beginExecution(origin: origin)

        do {
            // Redis 读命令与 SQL 读语句共用同一判定，避免两处前缀列表漂移。
            if Self.isReadStatement(sql, type: config.type) {
                // Redis 命令不是 SQL，不能注入 LIMIT。
                let limited = config.type == .redis
                    ? SQLQueryLimitResult(sql: resolved.sql, injectedLimit: nil, baseSQL: nil)
                    : SQLQueryLimiter.apply(resolved.sql, limit: queryRowLimit)
                let result = try await connection.query(limited.sql, params: resolved.params)
                guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }
                let hasMore = limited.injectedLimit.map { result.rows.count >= $0 } ?? false
                commitQueryResult(result, origin: origin, baseSQL: limited.baseSQL, baseParams: resolved.params, fetchedRows: result.rows.count, hasMore: hasMore)
                DatabaseManagerPluginSupport.debugLog.debug("\(self.t)查询成功，返回 \(result.rows.count) 行")
            } else {
                let affected = try await connection.execute(resolved.sql, params: resolved.params)
                guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }
                let result = QueryResult(columns: ["Result"], rows: [[.string("Success. Rows affected: \(affected)")]], rowsAffected: affected)
                commitQueryResult(result, origin: origin, baseSQL: nil, baseParams: nil, fetchedRows: 0, hasMore: false)
                DatabaseManagerPluginSupport.debugLog.debug("\(self.t)执行成功，影响 \(affected) 行")
            }
        } catch {
            guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }
            DatabaseManagerPluginSupport.debugLog.error("\(self.t)查询执行失败: \(error.localizedDescription)")
            // 断线类错误：一次自动重连并重跑当前语句（保留编辑器上下文）。
            let classified = DatabaseErrorClassifier.classify(error)
            if classified.category == .connectionLost, !isRetry, !didAttemptAutoReconnect {
                didAttemptAutoReconnect = true
                await connect(config: config, isReconnect: true)
                if isConnected {
                    isLoading = false
                    runningTabID = nil
                    await executeQuery(isRetry: true, sqlOverride: sqlOverride)
                    return
                }
            }
            commitError(error, origin: origin)
        }
        guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }
        finishExecution(origin: origin)
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
        let origin = workspace.activeTabID
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else { return }

        isLoadingMore = true
        let pageSize = max(queryRowLimit, 1)
        let sql = "\(baseSQL)\nLIMIT \(pageSize) OFFSET \(editorFetchedRows)"
        do {
            let result = try await connection.query(sql, params: editorBaseParams)
            guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else {
                isLoadingMore = false
                return
            }
            appendMoreRows(result, origin: origin, pageSize: pageSize)
        } catch {
            guard isCurrentConnection(generation, configId: config.id), sequence == executionSequence else {
                isLoadingMore = false
                return
            }
            commitError(error, origin: origin)
        }
        isLoadingMore = false
        if origin == workspace.activeTabID { syncActiveSnapshot() }
    }

    private func resetEditorPaging() {
        editorBaseSQL = nil
        editorBaseParams = nil
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
        let origin = workspace.activeTabID
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

        // 命名参数：整批预解析，缺值/非法即拦截（不进入执行）。
        var resolved: [(sql: String, params: [DatabaseValue]?)] = []
        for stmt in statements {
            do { resolved.append(try resolveParameters(stmt, type: config.type)) }
            catch { presentError(error); return }
        }

        isLoading = true
        runningTabID = origin
        clearForBatch(origin: origin)
        executionSequence += 1

        if batchPolicy == .wrapInTransaction {
            await executeBatchInTransaction(
                statements: statements, resolved: resolved, config: config, connection: connection, generation: generation, origin: origin
            )
            return
        }

        var executions: [StatementExecution] = []
        var lastSuccess: QueryResult?

        for (stmt, res) in zip(statements, resolved) {
            let start = Date()
            var exec = StatementExecution(sql: stmt)
            do {
                if Self.isReadStatement(stmt, type: config.type) {
                    let limited = config.type == .redis
                        ? SQLQueryLimitResult(sql: res.sql, injectedLimit: nil, baseSQL: nil)
                        : SQLQueryLimiter.apply(res.sql, limit: queryRowLimit)
                    let result = try await connection.query(limited.sql, params: res.params)
                    guard isCurrentConnection(generation, configId: config.id) else { return }
                    exec.result = result
                    lastSuccess = result
                } else {
                    let affected = try await connection.execute(res.sql, params: res.params)
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

        commitBatch(executions, lastSuccess: lastSuccess, rolledBack: false, origin: origin)
        isLoading = false
        runningTabID = nil
        await recordExecutedSQLs(statements, config: config)
    }

    /// 包裹事务的批量执行：任一语句失败即整体回滚并停止；全部成功才提交。
    ///
    /// SQL 引擎（MySQL/PG/SQLite）的读语句经同一连接的 `query` 执行（处于事务内），
    /// 写语句经事务 `execute`。Redis 走 MULTI/EXEC：所有命令入队，读命令返回 QUEUED，
    /// 真实回复在 EXEC 时产生，故本路径不逐句展示 Redis 读结果（MULTI 语义单独处理）。
    private func executeBatchInTransaction(
        statements: [String],
        resolved: [(sql: String, params: [DatabaseValue]?)],
        config: DatabaseConfig,
        connection: any DatabaseConnection,
        generation: Int,
        origin: UUID
    ) async {
        var executions: [StatementExecution] = []
        var lastSuccess: QueryResult?
        var rolledBack = false

        let transaction: any DatabaseTransaction
        do {
            transaction = try await connection.beginTransaction()
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            commitError(error, origin: origin)
            isLoading = false
            runningTabID = nil
            return
        }

        var failed = false
        for (stmt, res) in zip(statements, resolved) {
            let start = Date()
            var exec = StatementExecution(sql: stmt)
            do {
                if config.type == .redis {
                    let affected = try await transaction.execute(res.sql, params: res.params)
                    guard isCurrentConnection(generation, configId: config.id) else {
                        try? await transaction.rollback(); return
                    }
                    exec.result = QueryResult(columns: ["Result"], rows: [[.string("QUEUED")]], rowsAffected: affected)
                } else if Self.isReadStatement(stmt, type: config.type) {
                    let limited = SQLQueryLimiter.apply(res.sql, limit: queryRowLimit)
                    let result = try await connection.query(limited.sql, params: res.params)
                    guard isCurrentConnection(generation, configId: config.id) else {
                        try? await transaction.rollback(); return
                    }
                    exec.result = result
                    lastSuccess = result
                } else {
                    let affected = try await transaction.execute(res.sql, params: res.params)
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
            rolledBack = true
        } else {
            do {
                try await transaction.commit()
            } catch {
                guard isCurrentConnection(generation, configId: config.id) else { return }
                // SQL 引擎 COMMIT 失败可回滚；Redis EXEC 非原子回滚，不宣称已回滚。
                if config.type != .redis {
                    try? await transaction.rollback()
                    rolledBack = true
                }
                commitError(error, origin: origin)
            }
        }

        guard isCurrentConnection(generation, configId: config.id) else { return }
        commitBatch(executions, lastSuccess: lastSuccess, rolledBack: rolledBack, origin: origin)
        isLoading = false
        runningTabID = nil
        await recordExecutedSQLs(statements, config: config)
    }

    /// 判断一条 SQL 是否为"读"语句（走 query 路径）而非"写"（走 execute 路径）。
    public static func isReadStatement(_ sql: String, type: DatabaseType) -> Bool {
        if type == .redis {
            // Redis 无 RETURNING 语义，读判定直接复用写闸门的读白名单（未知命令保守按写），
            // 避免维护两份会漂移的前缀列表——HGETALL/TTL/TYPE/XRANGE 等读命令须走 query 取回结果。
            return !WriteGate.isWriteStatement(sql, type: .redis)
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

    /// 重执行一条历史：载入编辑器并立即在当前连接执行。
    public func reRunHistoryEntry(_ entry: QueryHistoryEntry) async {
        queryText = entry.sql
        showHistory = false
        await executeQuery()
    }

    /// 置顶/取消置顶一条历史并刷新列表。
    public func togglePinHistoryEntry(_ entry: QueryHistoryEntry) async {
        await historyStore.setPinned(id: entry.id, pinned: !entry.pinned)
        await refreshHistory()
    }

    /// 设置历史保留期（天，0 永久）：立即清理过期条目并刷新。
    public func setHistoryRetentionDays(_ days: Int) async {
        historyRetentionDays = max(0, days)
        await historyStore.setRetentionDays(days)
        await refreshHistory()
    }

    /// 删除某条历史。
    public func deleteHistoryEntry(_ entry: QueryHistoryEntry) async {
        await historyStore.delete(id: entry.id)
        await refreshHistory()
    }

    /// 清空全部历史。
    public func clearHistory() async {
        await historyStore.clear()
        history.removeAll()
    }

    /// 按当前搜索状态刷新历史列表（有关键字走全文搜索，否则取最近）。
    private func refreshHistory() async {
        if historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history = await historyStore.recent(limit: 100)
        } else {
            history = await historyStore.search(historySearchText)
        }
    }

    /// 记录已执行的 SQL（多语句时按语句逐条记）。
    ///
    /// `config` 由调用方在执行前快照传入：查询返回时连接可能已经切换，
    /// 历史必须归属真正执行它的连接。
    private func recordExecutedSQLs(_ statements: [String], config: DatabaseConfig) async {
        var schemaChanged = false
        for sql in statements {
            await historyStore.record(sql: sql, configName: config.name, database: config.database)
            if Self.isSchemaChangeStatement(sql) { schemaChanged = true }
        }
        // DDL 后结构缓存与补全元数据失效，下次浏览/补全重新读取 catalog。
        if schemaChanged {
            sqlCompletionProvider.invalidate(configId: config.id)
        }
        await loadRecentHistory()
    }

    // MARK: - 收藏查询与片段

    /// 把当前编辑器文本收藏为命名查询（归属当前连接）；同名同连接替换。空名/空 SQL 忽略。
    public func saveCurrentQuery(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !sql.isEmpty else { return }
        let configName = selectedConfig?.name ?? ""
        let database = activeDatabase ?? selectedConfig?.database ?? ""
        var list = savedQueries
        list.removeAll { $0.name == trimmedName && $0.configName == configName }
        list.append(SavedQuery(name: trimmedName, sql: sql, configName: configName, database: database))
        savedQueries = list
        savedQueryStore.saveQueries(list)
    }

    /// 把收藏查询载入编辑器（替换 queryText）。
    public func loadSavedQuery(_ query: SavedQuery) {
        queryText = query.sql
    }

    /// 重执行收藏查询：载入编辑器并立即在当前连接执行。
    public func runSavedQuery(_ query: SavedQuery) async {
        queryText = query.sql
        await executeQuery()
    }

    /// 重命名收藏查询；空名忽略。
    public func renameSavedQuery(id: UUID, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let index = savedQueries.firstIndex(where: { $0.id == id }) else { return }
        savedQueries[index].name = trimmedName
        savedQueryStore.saveQueries(savedQueries)
    }

    /// 删除收藏查询。
    public func deleteSavedQuery(_ query: SavedQuery) {
        savedQueries.removeAll { $0.id == query.id }
        savedQueryStore.saveQueries(savedQueries)
    }

    /// 新增片段；空名/空正文忽略，同名替换。
    public func addSnippet(name: String, body: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedBody.isEmpty else { return }
        var list = snippets
        list.removeAll { $0.name == trimmedName }
        list.append(Snippet(name: trimmedName, body: trimmedBody))
        snippets = list
        savedQueryStore.saveSnippets(list)
    }

    /// 删除片段。
    public func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        savedQueryStore.saveSnippets(snippets)
    }

    /// 在编辑器光标处插入片段（有选区则替换选区），展开占位符并选中首个非空默认值。
    public func insertSnippet(_ snippet: Snippet) {
        let expansion = SnippetExpander.expansion(snippet.body)
        let inserted = expansion.text
        let ns = queryText as NSString
        let selection = editorSelectionRange
        let replaceRange: NSRange
        if selection.location != NSNotFound, selection.length > 0,
           selection.location + selection.length <= ns.length {
            replaceRange = selection
        } else {
            let rawLocation = editorCursorLocation == NSNotFound ? ns.length : editorCursorLocation
            let location = max(0, min(rawLocation, ns.length))
            replaceRange = NSRange(location: location, length: 0)
        }
        queryText = ns.replacingCharacters(in: replaceRange, with: inserted)
        let base = replaceRange.location
        if let first = expansion.firstSelection {
            editorCursorLocation = base + first.location
            editorSelectionRange = NSRange(location: base + first.location, length: first.length)
        } else {
            let end = base + inserted.utf16.count
            editorCursorLocation = end
            editorSelectionRange = NSRange(location: end, length: 0)
        }
    }

    /// 是否为改变数据库结构的语句（CREATE/ALTER/DROP/TRUNCATE），用于失效结构缓存。
    public static func isSchemaChangeStatement(_ sql: String) -> Bool {
        let upper = SQLStatementParser.stripLiteralsAndComments(sql)
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return upper.hasPrefix("CREATE") || upper.hasPrefix("ALTER")
            || upper.hasPrefix("DROP") || upper.hasPrefix("TRUNCATE")
    }

    /// 单页 SCAN 的目标键数与每次 SCAN 的工作量提示。分页加载解除「一次扫完整库」的呈现瓶颈：
    /// 首屏只取一页，用户可「加载更多」逐页深入数百万键的键空间而不冻结界面。
    private static let redisScanPageTarget = 1000
    private static let redisScanCountHint = 200

    /// 重建命名空间键树（键集合或分隔符变化时调用）。
    private func rebuildRedisKeyTree() {
        redisKeyTree = RedisKeyTreeBuilder.build(keys: redisKeys, separator: redisKeySeparator)
    }

    /// 连接切换/断开时清空键浏览器全部状态，避免旧连接的键/详情泄漏到新连接。
    private func clearRedisBrowserState() {
        redisKeys = []
        redisKeyTree = []
        redisScanCursor = "0"
        redisHasMoreKeys = false
        selectedRedisKey = nil
        selectedRedisValue = nil
        redisValueError = nil
    }

    /// 加载 Redis 键列表首页（重置游标后扫描一页），并重建命名空间键树。
    public func loadRedisKeys() async {
        redisKeys = []
        redisScanCursor = "0"
        redisHasMoreKeys = false
        rebuildRedisKeyTree()
        await scanRedisKeysPage(reset: true)
    }

    /// 从当前游标继续扫描下一页键（侧边栏「加载更多」）。
    public func loadMoreRedisKeys() async {
        guard redisHasMoreKeys, !isLoadingRedisKeys else { return }
        await scanRedisKeysPage(reset: false)
    }

    /// SCAN 分页核心：经 ``RedisCursorScanning`` 协议穿透安全模式/SSH 包装连接，
    /// 累计到一页目标或游标归零即停，去重保序后更新键集合与树。
    private func scanRedisKeysPage(reset: Bool) async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type == .redis else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        guard let redis = connection as? RedisCursorScanning else {
            presentError(DatabaseError.connectionFailed("Unexpected Redis connection type"))
            return
        }
        isLoadingRedisKeys = true
        defer { isLoadingRedisKeys = false }
        do {
            var cursor = reset ? "0" : redisScanCursor
            var collected = reset ? [] : redisKeys
            let startCount = collected.count
            repeat {
                let step = try await redis.scanKeys(cursor: cursor, match: "*", count: Self.redisScanCountHint)
                guard isCurrentConnection(generation, configId: config.id) else { return }
                collected.append(contentsOf: step.keys)
                cursor = step.nextCursor
            } while cursor != "0" && (collected.count - startCount) < Self.redisScanPageTarget
            guard isCurrentConnection(generation, configId: config.id) else { return }
            // SCAN 跨迭代可能重复返回同一键：去重并保持首次出现顺序。
            var seen = Set<String>()
            redisKeys = collected.filter { seen.insert($0).inserted }
            redisScanCursor = cursor
            redisHasMoreKeys = cursor != "0"
            rebuildRedisKeyTree()
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            presentError(error)
        }
    }

    /// 打开指定 Redis 键：读取 TYPE + TTL + 类型化值，落入键详情面板。
    /// 读命令经 params 通道传键，避免键名含空格/引号时的转义问题。
    public func openRedisKey(_ key: String) async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type == .redis else { return }
        guard let connection = await manager.getConnection(for: config.id) else {
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        isLoadingRedisValue = true
        redisValueError = nil
        defer { isLoadingRedisValue = false }
        do {
            let typeResult = try await connection.query("TYPE", params: [.string(key)])
            guard isCurrentConnection(generation, configId: config.id) else { return }
            let type = RedisKeyType(commandResult: Self.redisScalarString(typeResult))
            let ttlResult = try await connection.query("TTL", params: [.string(key)])
            guard isCurrentConnection(generation, configId: config.id) else { return }
            let ttl = Self.redisScalarInt(ttlResult) ?? -1
            selectedRedisKey = RedisKeyInfo(key: key, type: type, ttl: ttl)
            if let read = RedisKeyCommands.read(type: type, key: key) {
                let valueResult = try await connection.query(read.command, params: read.params)
                guard isCurrentConnection(generation, configId: config.id) else { return }
                selectedRedisValue = RedisKeyValue.from(type: type, result: valueResult)
            } else {
                selectedRedisValue = .string(.null)
            }
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            redisValueError = error.localizedDescription
        }
    }

    /// 重新读取当前打开键的类型/TTL/值（编辑后或手动刷新）。
    public func refreshSelectedRedisValue() async {
        guard let key = selectedRedisKey?.key else { return }
        await openRedisKey(key)
    }

    /// 关闭键详情，回到命令编辑器。
    public func closeRedisKey() {
        selectedRedisKey = nil
        selectedRedisValue = nil
        redisValueError = nil
    }

    /// 执行一次类型化键编辑：经写闸门（confirmWrites 确认 / readOnly 拒绝）后下发命令，
    /// 成功后本地更新键集合与树并刷新当前键值，避免整库重扫。
    public func applyRedisEdit(_ edit: RedisKeyEdit) async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type == .redis else { return }
        guard let connection = await manager.getConnection(for: config.id) else {
            presentError(DatabaseError.connectionFailed("Not connected to a database"))
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        switch await authorizeWrites([edit.command], type: .redis, kind: .tableEdit) {
        case .authorized: break
        case .cancelled: return
        case .blocked: presentReadOnlyError(); return
        }
        do {
            _ = try await connection.execute(edit.command, params: edit.params)
            guard isCurrentConnection(generation, configId: config.id) else { return }
            if case .delete = edit {
                redisKeys.removeAll { $0 == edit.key }
                if selectedRedisKey?.key == edit.key { closeRedisKey() }
            } else {
                if !redisKeys.contains(edit.key) { redisKeys.append(edit.key) }
                if selectedRedisKey?.key == edit.key { await refreshSelectedRedisValue() }
            }
            rebuildRedisKeyTree()
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            presentError(error)
        }
    }

    /// 取整形结果首行首列的字符串标量（TYPE 等）。
    private static func redisScalarString(_ result: QueryResult) -> String {
        guard let value = result.rows.first?.first else { return "" }
        if case .string(let s) = value { return s }
        return value.description
    }

    /// 取整形结果首行首列的整数标量（TTL 等）。
    private static func redisScalarInt(_ result: QueryResult) -> Int? {
        guard let value = result.rows.first?.first else { return nil }
        switch value {
        case .integer(let i): return i
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// 加载当前连接在侧边栏可见的对象分类（表/视图/例程…），结果写入 ``schemaCache``。
    /// MySQL/PG 首次连接后侧边栏不再为空，全靠这里填充。
    public func refreshSidebarObjects() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type != .redis else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        // Reload 同时刷新可切换的库/schema 列表（保留当前活动选择），使新建库/schema 可见。
        await refreshSchemaLists()
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let database: String? = config.type == .sqlite ? nil : (activeDatabase ?? config.database)
        let schema: String? = config.type == .postgresql ? activeSchema : nil
        for kind in config.type.sidebarObjectKinds {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            // 这是用户可见的 Reload：必须绕过缓存重新读库，
            // 否则新建/删除表后对象树仍显示旧结构。
            _ = try? await schemaCache.objects(
                for: config,
                kind: kind,
                database: database,
                schema: schema,
                connection: connection,
                refresh: true
            )
        }
    }

    /// 加载当前库/schema 的只读 ER 图：取表集合，逐表读结构（含外键），构建图模型。
    /// 超大库按上限截断逐表 describe，避免一次性introspection 卡死；被引用但未描述的表由构建器补 stub。
    public func loadERDiagram(refresh: Bool = false) async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type.capabilities.supportsForeignKeys else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        isLoadingERDiagram = true
        erDiagramError = nil
        defer { isLoadingERDiagram = false }
        let database: String? = config.type == .sqlite ? nil : (activeDatabase ?? config.database)
        let schema: String? = config.type == .postgresql ? activeSchema : nil
        do {
            let tables = try await schemaCache.objects(
                for: config, kind: .table, database: database, schema: schema,
                connection: connection, refresh: refresh
            )
            guard isCurrentConnection(generation, configId: config.id) else { return }
            var schemas: [TableSchema] = []
            for object in tables.prefix(200) {
                guard isCurrentConnection(generation, configId: config.id) else { return }
                if let tableSchema = try? await schemaCache.tableSchema(
                    for: object, config: config, connection: connection, refresh: refresh
                ) {
                    schemas.append(tableSchema)
                }
            }
            guard isCurrentConnection(generation, configId: config.id) else { return }
            erDiagram = ERDiagramBuilder.build(from: schemas)
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            erDiagramError = error.localizedDescription
        }
    }

    /// 对当前编辑器语句执行 EXPLAIN，解析为计划树并展示。
    ///
    /// 普通 EXPLAIN 只读直接放行；PG 的 `analyze` 走 `EXPLAIN (ANALYZE, FORMAT JSON)`，
    /// 会真实执行被解释语句——含 DML 时由 ``WriteGate`` 识别为写并经安全模式闸门
    /// （readOnly 拒绝、confirmWrites 弹确认），与其余写路径一致。Redis 无 EXPLAIN，忽略。
    public func explainCurrentQuery(analyze: Bool = false) async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type != .redis else { return }
        let sql = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }

        let resolved: (sql: String, params: [DatabaseValue]?)
        do {
            resolved = try resolveParameters(sql, type: config.type)
        } catch {
            presentError(error)
            return
        }

        let useAnalyze = analyze && config.type == .postgresql
        let explainSQL = Self.explainStatement(resolved.sql, type: config.type, analyze: useAnalyze)
        switch await authorizeWrites([explainSQL], type: config.type, kind: .query) {
        case .authorized: break
        case .cancelled: return
        case .blocked: presentReadOnlyError(); return
        }

        isLoadingPlan = true
        queryPlanError = nil
        defer { isLoadingPlan = false }
        do {
            let result = try await connection.query(explainSQL, params: resolved.params)
            guard isCurrentConnection(generation, configId: config.id) else { return }
            queryPlan = Self.parsePlan(result, type: config.type, analyze: useAnalyze)
            isQueryPlanPresented = true
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            queryPlanError = error.localizedDescription
        }
    }

    /// 按引擎拼装 EXPLAIN 语句。PG 用 FORMAT JSON（ANALYZE 可选），MySQL 用 FORMAT=JSON，
    /// SQLite 用 QUERY PLAN（树形 detail）。
    nonisolated static func explainStatement(_ sql: String, type: DatabaseType, analyze: Bool) -> String {
        switch type {
        case .postgresql:
            return analyze ? "EXPLAIN (ANALYZE, FORMAT JSON) \(sql)" : "EXPLAIN (FORMAT JSON) \(sql)"
        case .mysql:
            return "EXPLAIN FORMAT=JSON \(sql)"
        case .sqlite:
            return "EXPLAIN QUERY PLAN \(sql)"
        case .redis:
            return sql
        }
    }

    /// 把 EXPLAIN 结果行解析为统一计划树。PG/MySQL JSON 为单行单列文本；
    /// MySQL 旧版表格输出回退到逐行解析；SQLite 直接解析 QUERY PLAN 行。
    nonisolated static func parsePlan(_ result: QueryResult, type: DatabaseType, analyze: Bool) -> QueryPlan {
        switch type {
        case .postgresql:
            let text = result.rows.first.flatMap { SchemaRowDecoder.string($0, at: 0) } ?? ""
            return PostgreSQLPlanParser.parse(text, analyze: analyze)
        case .mysql:
            if result.columns.count == 1,
               let text = result.rows.first.flatMap({ SchemaRowDecoder.string($0, at: 0) }) {
                let plan = MySQLPlanParser.parseJSON(text)
                if !plan.isEmpty { return plan }
            }
            return MySQLPlanParser.parseTabular(result)
        case .sqlite:
            return SQLitePlanParser.parse(result)
        case .redis:
            return QueryPlan(engine: .redis)
        }
    }

    /// 清空库/schema 上下文（连接切换/断开时调用，避免旧连接的库/schema 泄漏到新连接）。
    private func resetSchemaContext() {
        activeDatabase = nil
        activeSchema = nil
        availableDatabases = []
        availableSchemas = []
        isLoadingSchemaContext = false
        erDiagram = nil
        erDiagramError = nil
        queryPlan = nil
        queryPlanError = nil
    }

    /// 确立当前连接的库/schema 上下文：活动库默认取连接配置，PG 活动 schema 默认 public
    /// （不存在时取首个），并加载可切换列表。
    private func loadSchemaContext() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type == .mysql || config.type == .postgresql else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        isLoadingSchemaContext = true
        defer { isLoadingSchemaContext = false }
        activeDatabase = config.database
        activeSchema = config.type == .postgresql ? "public" : nil
        await refreshSchemaLists()
        guard isCurrentConnection(generation, configId: config.id) else { return }
        if config.type == .postgresql, let schema = activeSchema, !availableSchemas.contains(schema) {
            activeSchema = availableSchemas.contains("public") ? "public" : availableSchemas.first
        }
    }

    /// 重新加载可切换的库列表（MySQL/PG）与 schema 列表（PG），保留当前活动库/schema 选择。
    /// 供 Reload 与切换后刷新使用，使外部新建的库/schema 进入选择菜单。
    private func refreshSchemaLists() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, config.type == .mysql || config.type == .postgresql else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        if let databases = try? await schemaCache.loadDatabases(for: config, connection: connection, refresh: true) {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            availableDatabases = databases
        }
        if config.type == .postgresql {
            if let schemas = try? await schemaCache.loadSchemas(for: config, database: activeDatabase ?? config.database, connection: connection, refresh: true) {
                guard isCurrentConnection(generation, configId: config.id) else { return }
                availableSchemas = schemas
            }
        } else {
            availableSchemas = []
        }
    }

    /// 切换活动库（MySQL/PG）：库名在连接时绑定，故以新库名重连（保留编辑器文本，
    /// 清掉旧库的打开表上下文）。不改动已保存的连接配置，切换仅是会话级上下文。
    public func switchDatabase(_ database: String) async {
        guard let config = selectedConfig, config.type == .mysql || config.type == .postgresql else { return }
        guard !database.isEmpty, database != (activeDatabase ?? config.database) else { return }
        var updated = config
        updated.database = database
        openTableObject = nil
        selectedTableSchema = nil
        await connect(config: updated, isReconnect: true)
    }

    /// 切换活动 schema（PG）：下发 SET search_path 使未限定查询跟随，再刷新对象树。
    /// search_path 是会话上下文而非数据写，直接经连接下发（不经写闸门），readOnly 亦允许。
    public func switchSchema(_ schema: String) async {
        guard let config = selectedConfig, config.type == .postgresql else { return }
        guard !schema.isEmpty, schema != activeSchema else { return }
        let generation = connectionGeneration
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let quoted = Self.quoteIdentifier(schema, for: .postgresql)
        do {
            _ = try await connection.execute("SET search_path TO \(quoted)", params: nil)
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            presentError(error)
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        activeSchema = schema
        openTableObject = nil
        selectedTableSchema = nil
        await refreshSidebarObjects()
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
            resetKeyset()
            resetGridFind()
            loadGridLayout()
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
        objectDefinitionDraft = nil
        definitionSaveError = nil
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

    /// 当前对象定义是否可编辑：例程（MySQL/PG）与触发器（MySQL/PG）。索引/表/视图不在此面板编辑。
    public var canEditDefinition: Bool {
        guard let config = selectedConfig, let object = objectDefinition?.object else { return false }
        switch object.kind {
        case .procedure, .function:
            return config.type.capabilities.supportsRoutines
        case .trigger:
            return config.type == .mysql || config.type == .postgresql
        default:
            return false
        }
    }

    /// 进入编辑：以当前定义源码为草稿。PG 例程源码已是 CREATE OR REPLACE，可直接替换；
    /// MySQL 例程/触发器与 PG 触发器保存时先 DROP 再 CREATE（见 ``saveDefinition()``）。
    public func beginEditDefinition() {
        guard canEditDefinition, let ddl = objectDefinition?.ddl, !ddl.isEmpty else { return }
        definitionSaveError = nil
        objectDefinitionDraft = ddl
    }

    public func cancelEditDefinition() {
        objectDefinitionDraft = nil
        definitionSaveError = nil
    }

    /// 保存编辑后的对象定义：经写闸门（DDL 属写），按引擎生成必要的 DROP 前置语句，
    /// 再把编辑后的 CREATE 源码作为单条语句执行（保留例程体内部分号），成功后重载定义。
    public func saveDefinition() async {
        guard let config = selectedConfig,
              let display = objectDefinition,
              canEditDefinition,
              let source = objectDefinitionDraft?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return }
        let generation = connectionGeneration
        guard let connection = await manager.getConnection(for: config.id) else {
            definitionSaveError = DatabaseError.connectionFailed("No active connection").localizedDescription
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }

        var statements: [String] = []
        if let drop = await definitionDropStatement(for: display.object, type: config.type, connection: connection) {
            statements.append(drop)
        }
        statements.append(source)

        switch await authorizeWrites(statements, type: config.type, kind: .schemaChange) {
        case .authorized: break
        case .cancelled: return
        case .blocked: definitionSaveError = readOnlySchemaErrorMessage; return
        }
        isSavingDefinition = true
        definitionSaveError = nil
        defer { isSavingDefinition = false }
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
            guard isCurrentConnection(generation, configId: config.id) else { return }
            objectDefinitionDraft = nil
            await openDefinition(of: display.object)
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            definitionSaveError = error.localizedDescription
        }
    }

    /// 替换对象定义所需的前置 DROP 语句；PG 例程用 CREATE OR REPLACE 无需 DROP，返回 nil。
    /// PG 触发器的 DROP 需要 ON 表名，从 catalog 读取。
    private func definitionDropStatement(for object: DatabaseObject, type: DatabaseType, connection: any DatabaseConnection) async -> String? {
        let qualified = Self.qualifiedName(for: object, type: type)
        switch (type, object.kind) {
        case (.mysql, .procedure):
            return "DROP PROCEDURE IF EXISTS \(qualified);"
        case (.mysql, .function):
            return "DROP FUNCTION IF EXISTS \(qualified);"
        case (.mysql, .trigger):
            return "DROP TRIGGER IF EXISTS \(qualified);"
        case (.postgresql, .trigger):
            let schema = object.schema ?? "public"
            let sql = """
            SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname)
            FROM pg_trigger tg
            JOIN pg_class c ON c.oid = tg.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(Self.escapeSQLLiteral(schema))' AND tg.tgname = '\(Self.escapeSQLLiteral(object.name))'
              AND NOT tg.tgisinternal
            LIMIT 1;
            """
            guard let row = try? await connection.query(sql, params: nil).rows.first,
                  let table = SchemaRowDecoder.string(row, at: 0) else { return nil }
            return "DROP TRIGGER IF EXISTS \(Self.quoteIdentifier(object.name, for: type)) ON \(table);"
        default:
            return nil
        }
    }

    nonisolated static func escapeSQLLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// 关闭表浏览，回到 SQL 编辑器。
    public func closeTableBrowser() {
        openTableObject = nil
        selectedTableSchema = nil
        tableSchemaError = nil
        schemaChangeManager = nil
        tableRowCount = nil
        queryResult = nil
        resetGridFind()
    }

    /// 从表浏览切到 SQL 编辑器，但保留当前 queryText/queryResult（让用户可基于浏览语句继续编辑）。
    public func switchToQueryEditor() {
        openTableObject = nil
        selectedTableSchema = nil
        tableSchemaError = nil
        schemaChangeManager = nil
        resetGridFind()
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

    /// 打开建表面板（清空上次错误）。
    public func presentCreateTable() {
        createTableError = nil
        isCreateTablePresented = true
    }

    /// 当前连接上下文下建表草稿的 DDL 预览（库/schema 限定与对象树一致）。
    public func createTablePreview(_ draft: NewTableDraft) -> String {
        guard let config = selectedConfig, config.type != .redis else { return "" }
        let database: String? = config.type == .sqlite ? nil : (activeDatabase ?? config.database)
        let schema: String? = config.type == .postgresql ? activeSchema : nil
        return CreateTableDDLGenerator.preview(draft, type: config.type, database: database, schema: schema)
    }

    /// 校验并执行建表草稿：DDL 属写操作，经安全模式闸门（readOnly 拒绝、confirmWrites 弹确认），
    /// 事务内逐句执行；成功后刷新对象树并打开新表。复用与改表一致的写管线。
    public func createTable(_ draft: NewTableDraft) async {
        guard let config = selectedConfig, config.type != .redis,
              config.type.capabilities.supportsSchemaEditing else { return }
        do {
            try CreateTableDDLGenerator.validate(draft)
        } catch {
            createTableError = error.localizedDescription
            return
        }
        let generation = connectionGeneration
        guard let connection = await manager.getConnection(for: config.id) else {
            createTableError = DatabaseError.connectionFailed("No active connection").localizedDescription
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let database: String? = config.type == .sqlite ? nil : (activeDatabase ?? config.database)
        let schema: String? = config.type == .postgresql ? activeSchema : nil
        let statements = CreateTableDDLGenerator.statements(draft, type: config.type, database: database, schema: schema)
        switch await authorizeWrites(statements, type: config.type, kind: .schemaChange) {
        case .authorized: break
        case .cancelled: return
        case .blocked: createTableError = readOnlySchemaErrorMessage; return
        }
        isCreatingTable = true
        createTableError = nil
        defer { isCreatingTable = false }
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
            guard isCurrentConnection(generation, configId: config.id) else { return }
            isCreateTablePresented = false
            await refreshSidebarObjects()
            await openObject(DatabaseObject(kind: .table, name: draft.name, database: database, schema: schema))
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            createTableError = error.localizedDescription
        }
    }

    // MARK: - 数据导入（CSV/JSON）

    /// 打开导入向导并重置上一次的状态。
    public func presentImportData() {
        importFileURL = nil
        importFormat = nil
        importSourceColumns = []
        importPreviewRows = []
        importInferredTypes = []
        importError = nil
        importCompleted = false
        importBadRows = []
        importedRowCount = 0
        importProgress = 0
        isImportDataPresented = true
    }

    /// 读取文件头部：格式检测 + 源列名 + 预览行（≤50）+ 类型推断采样（≤200 行）。
    /// CSV 只读前 256KB（流式，不整载）；JSON 整载解析（对象数组/NDJSON）。
    public func loadImportPreview(url: URL) async {
        importError = nil
        importCompleted = false
        importFileURL = url
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let head = try Self.readImportHead(url: url, limit: 256 * 1024)
            let format = ImportFileFormat.detect(fileName: url.lastPathComponent, head: head)
            importFormat = format
            switch format {
            case .csv:
                let parser = CSVStreamParser()
                var rows = parser.feed(Data(head.utf8))
                rows += parser.finish()
                guard !rows.isEmpty else { throw ImportError.emptyFile }
                let columns: [String]
                let dataRows: [[String]]
                if importHasHeader {
                    columns = rows[0].map { $0.trimmingCharacters(in: .whitespaces) }
                    guard !columns.isEmpty, columns.allSatisfy({ !$0.isEmpty }) else { throw ImportError.noColumns }
                    dataRows = Array(rows.dropFirst())
                } else {
                    let width = rows.map(\.count).max() ?? 0
                    guard width > 0 else { throw ImportError.noColumns }
                    columns = (1...width).map { "Column \($0)" }
                    dataRows = rows
                }
                importSourceColumns = columns
                importPreviewRows = dataRows.prefix(50).map { row in
                    columns.indices.map { index in index < row.count ? ImportCell.text(row[index]) : .missing }
                }
                let samples = Array(dataRows.prefix(200))
                importInferredTypes = columns.indices.map { index in
                    ImportTypeInference.infer(samples.compactMap { $0.count > index ? $0[index] : nil })
                }
            case .json:
                let text = try String(contentsOf: url, encoding: .utf8)
                let parsed = try JSONImportParser.parse(text)
                guard !parsed.columns.isEmpty else { throw ImportError.noColumns }
                importSourceColumns = parsed.columns
                importPreviewRows = Array(parsed.rows.prefix(50))
                importInferredTypes = parsed.columns.indices.map { index in
                    ImportTypeInference.infer(parsed.rows.prefix(200).compactMap { row in
                        guard index < row.count, case .text(let s) = row[index] else { return nil }
                        return s
                    })
                }
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    /// 当前连接活动上下文中的表列表（导入目标选择用）。
    public func loadImportTargetTables() async -> [DatabaseObject] {
        guard let config = selectedConfig, config.type != .redis else { return [] }
        guard let connection = await manager.getConnection(for: config.id) else { return [] }
        let database: String? = config.type == .sqlite ? nil : (activeDatabase ?? config.database)
        let schema: String? = config.type == .postgresql ? activeSchema : nil
        let objects = (try? await schemaCache.objects(for: config, kind: .table, database: database, schema: schema, connection: connection)) ?? []
        return objects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 目标表的列名（导入映射用）。
    public func loadImportTargetColumns(_ object: DatabaseObject) async -> [String] {
        guard let config = selectedConfig else { return [] }
        guard let connection = await manager.getConnection(for: config.id) else { return [] }
        let schema = try? await schemaCache.tableSchema(for: object, config: config, connection: connection)
        return schema?.columns.map { $0.name } ?? []
    }

    /// 启动导入（可取消）：批量参数化 INSERT + 事务 + 进度 + 坏行报告，经写闸门。
    public func startImport(target: ImportTarget, mappings: [ImportColumnMapping], options: ImportOptions = ImportOptions()) {
        importTask?.cancel()
        importError = nil
        importCompleted = false
        importBadRows = []
        importedRowCount = 0
        importProgress = 0
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            await self.performImport(target: target, mappings: mappings, options: options)
        }
    }

    public func cancelImport() {
        importTask?.cancel()
    }

    /// 等待导入任务结束（测试用）。
    func waitForImport() async {
        await importTask?.value
    }

    private func performImport(target: ImportTarget, mappings: [ImportColumnMapping], options: ImportOptions) async {
        defer { isImporting = false }
        guard let config = selectedConfig, config.type != .redis else { return }
        guard let url = importFileURL, let format = importFormat else {
            importError = ImportError.emptyFile.localizedDescription
            return
        }
        do {
            try ImportMappingBuilder.validate(mappings)
        } catch {
            importError = error.localizedDescription
            return
        }
        let generation = connectionGeneration
        guard let connection = await manager.getConnection(for: config.id) else {
            importError = DatabaseError.connectionFailed("No active connection").localizedDescription
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let database: String? = config.type == .sqlite ? nil : (activeDatabase ?? config.database)
        let schema: String? = config.type == .postgresql ? activeSchema : nil

        let mapped = mappings.filter { mapping in
            guard let target = mapping.targetColumn else { return false }
            return !target.isEmpty
        }
        let targetColumns = mapped.compactMap { $0.targetColumn }
        let sourceIndices = mapped.map { importSourceColumns.firstIndex(of: $0.sourceColumn) ?? -1 }
        let tableObject: DatabaseObject
        var createStatements: [String] = []
        let columnTypes: [ImportColumnType]
        switch target {
        case .existingTable(let object):
            tableObject = object
            do {
                let tableSchema = try await schemaCache.tableSchema(for: object, config: config, connection: connection)
                guard isCurrentConnection(generation, configId: config.id) else { return }
                columnTypes = targetColumns.map { name in
                    tableSchema.columns.first { $0.name.lowercased() == name.lowercased() }
                        .map { ImportColumnType.from(sqlType: $0.dataType) } ?? .text
                }
            } catch {
                importError = error.localizedDescription
                return
            }
        case .newTable(let draft):
            do {
                try CreateTableDDLGenerator.validate(draft)
            } catch {
                importError = error.localizedDescription
                return
            }
            tableObject = DatabaseObject(kind: .table, name: draft.name, database: database, schema: schema)
            createStatements = CreateTableDDLGenerator.statements(draft, type: config.type, database: database, schema: schema)
            columnTypes = mapped.map(\.inferredType)
        }

        // 占位符上限钳制（MySQL/PG 单语句绑定参数上限 65535）。
        let batchSize = max(1, min(options.batchSize, 60000 / max(1, targetColumns.count)))
        let insertSQL = ImportSQLBuilder.insertStatement(table: tableObject, columns: targetColumns, rowCount: batchSize, type: config.type)
        switch await authorizeWrites(createStatements + [insertSQL], type: config.type, kind: .batch) {
        case .authorized: break
        case .cancelled: return
        case .blocked:
            importError = pluginLocalization.string("This connection is read-only. Import is blocked. Edit the connection to change its safe mode.")
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let transaction = try await connection.beginTransaction()
            do {
                for statement in createStatements {
                    _ = try await transaction.execute(statement, params: nil)
                }
                var batch: [[DatabaseValue]] = []
                var batchRowNumbers: [Int] = []
                var rowNumber = 0
                var inserted = 0
                var badRows: [ImportBadRow] = []

                func statementSQL(_ sql: String) async throws {
                    _ = try await transaction.execute(sql, params: nil)
                }
                // 批失败（约束冲突等）回滚到批保存点后逐行重试定位坏行；
                // PG 事务内任何错误都会中止整个事务，故每批/每行均经保存点隔离。
                func flushBatch() async throws {
                    guard !batch.isEmpty else { return }
                    let sql = batch.count == batchSize ? insertSQL : ImportSQLBuilder.insertStatement(table: tableObject, columns: targetColumns, rowCount: batch.count, type: config.type)
                    let singleSQL = ImportSQLBuilder.insertStatement(table: tableObject, columns: targetColumns, rowCount: 1, type: config.type)
                    try await statementSQL("SAVEPOINT lode_batch")
                    do {
                        _ = try await transaction.execute(sql, params: batch.flatMap { $0 })
                        try await statementSQL("RELEASE SAVEPOINT lode_batch")
                        inserted += batch.count
                    } catch {
                        try? await statementSQL("ROLLBACK TO SAVEPOINT lode_batch")
                        try? await statementSQL("RELEASE SAVEPOINT lode_batch")
                        if options.badRowStrategy == .abort { throw error }
                        for (index, row) in batch.enumerated() {
                            do {
                                try await statementSQL("SAVEPOINT lode_row")
                                _ = try await transaction.execute(singleSQL, params: row)
                                try await statementSQL("RELEASE SAVEPOINT lode_row")
                                inserted += 1
                            } catch {
                                try? await statementSQL("ROLLBACK TO SAVEPOINT lode_row")
                                try? await statementSQL("RELEASE SAVEPOINT lode_row")
                                badRows.append(ImportBadRow(rowNumber: batchRowNumbers[index], message: error.localizedDescription))
                            }
                        }
                    }
                    batch.removeAll(keepingCapacity: true)
                    batchRowNumbers.removeAll(keepingCapacity: true)
                    importedRowCount = inserted
                    importBadRows = badRows
                }

                func ingest(_ cells: [ImportCell], skipBlank: Bool) async throws {
                    if skipBlank, cells.allSatisfy({ cell in
                        if case .text(let s) = cell { return s.trimmingCharacters(in: .whitespaces).isEmpty }
                        return cell == .missing
                    }) { return }
                    rowNumber += 1
                    let values: [DatabaseValue]
                    do {
                        values = try mapped.enumerated().map { index, mapping in
                            let sourceIndex = sourceIndices[index]
                            let cell: ImportCell = sourceIndex >= 0 && sourceIndex < cells.count ? cells[sourceIndex] : .missing
                            return try ImportValueConverter.databaseValue(
                                cell, as: columnTypes[index],
                                column: mapping.targetColumn ?? mapping.sourceColumn,
                                emptyAsNull: options.emptyAsNull
                            )
                        }
                    } catch {
                        if options.badRowStrategy == .abort { throw error }
                        badRows.append(ImportBadRow(rowNumber: rowNumber, message: error.localizedDescription))
                        importBadRows = badRows
                        return
                    }
                    batch.append(values)
                    batchRowNumbers.append(rowNumber)
                    if batch.count >= batchSize {
                        try await flushBatch()
                        try Task.checkCancellation()
                    }
                }

                switch format {
                case .csv:
                    let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let parser = CSVStreamParser()
                    var headerSkipped = !importHasHeader
                    var bytesRead = 0
                    func consume(_ raw: [String]) async throws {
                        if !headerSkipped {
                            headerSkipped = true
                            return
                        }
                        try await ingest(raw.map { .text($0) }, skipBlank: true)
                    }
                    while true {
                        try Task.checkCancellation()
                        guard let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty else { break }
                        bytesRead += chunk.count
                        for raw in parser.feed(chunk) {
                            try await consume(raw)
                        }
                        importProgress = fileSize > 0 ? min(1, Double(bytesRead) / Double(fileSize)) : 0
                    }
                    for raw in parser.finish() {
                        try await consume(raw)
                    }
                case .json:
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let parsed = try JSONImportParser.parse(text)
                    let total = max(1, parsed.rows.count)
                    for (index, row) in parsed.rows.enumerated() {
                        try Task.checkCancellation()
                        try await ingest(row, skipBlank: false)
                        importProgress = Double(index + 1) / Double(total)
                    }
                }
                try await flushBatch()
                try await transaction.commit()
                guard isCurrentConnection(generation, configId: config.id) else { return }
                importProgress = 1
                importCompleted = true
                await refreshSidebarObjects()
                if case .newTable = target {
                    await openObject(tableObject)
                }
            } catch {
                try? await transaction.rollback()
                throw error
            }
        } catch {
            guard isCurrentConnection(generation, configId: config.id) else { return }
            if error is CancellationError {
                importError = pluginLocalization.string("Import cancelled.")
            } else {
                importError = error.localizedDescription
            }
        }
    }

    private nonisolated static func readImportHead(url: URL, limit: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 数据导出（CSV/JSON/SQL/Markdown）

    /// 打开导出面板并重置上一次状态，载入已保存的预设。
    public func presentExport() {
        exportError = nil
        exportCompleted = false
        exportedRowCount = 0
        exportProgress = 0
        loadExportPresets()
        isExportPresented = true
    }

    private func loadExportPresets() {
        guard let data = workspaceDefaults.data(forKey: "DatabaseManager.exportPresets"),
              let saved = try? JSONDecoder().decode([ExportPreset].self, from: data) else {
            exportPresets = []
            return
        }
        exportPresets = saved
    }

    private func persistExportPresets() {
        if let data = try? JSONEncoder().encode(exportPresets) {
            workspaceDefaults.set(data, forKey: "DatabaseManager.exportPresets")
        }
    }

    /// 保存预设（同名替换）；空白名忽略。
    public func saveExportPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        exportPresets.removeAll { $0.name == trimmed }
        exportPresets.append(ExportPreset(name: trimmed, format: exportFormat, range: exportRange))
        persistExportPresets()
    }

    public func deleteExportPreset(id: UUID) {
        exportPresets.removeAll { $0.id == id }
        persistExportPresets()
    }

    /// 应用预设：设置格式与行范围。
    public func applyExportPreset(_ preset: ExportPreset) {
        exportFormat = preset.format
        exportRange = preset.range
    }

    /// 启动导出到指定文件（可取消）。只读 SELECT + 本地写盘，不经写闸门。
    public func startExport(to url: URL) {
        exportTask?.cancel()
        exportError = nil
        exportCompleted = false
        exportedRowCount = 0
        exportProgress = 0
        isExporting = true
        exportTask = Task { [weak self] in
            guard let self else { return }
            await self.performExport(to: url)
        }
    }

    public func cancelExport() {
        exportTask?.cancel()
    }

    /// 等待导出任务结束（测试用）。
    func waitForExport() async {
        await exportTask?.value
    }

    private func performExport(to url: URL) async {
        defer { isExporting = false }
        guard let config = selectedConfig, config.type != .redis else { return }
        let generation = connectionGeneration
        let format = exportFormat
        let range = exportRange
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // 当前页：直接写已加载的结果，无需再查库。
        if range == .currentPage {
            guard let result = queryResult, !result.columns.isEmpty else {
                exportError = pluginLocalization.string("No data to export.")
                return
            }
            let tableExpr = exportTableExpr(config: config)
            do {
                try Self.writeExportFile(url: url, format: format, columns: result.columns, rows: result.rows, tableExpr: tableExpr, dialect: config.type)
                exportedRowCount = result.rows.count
                exportProgress = 1
                exportCompleted = true
            } catch {
                try? FileManager.default.removeItem(at: url)
                exportError = error.localizedDescription
            }
            return
        }

        // 全部行 / 筛选结果：流式分页写盘，任意行数都不整载。
        guard let table = openTableObject else {
            exportError = pluginLocalization.string("No data to export.")
            return
        }
        guard let connection = await manager.getConnection(for: config.id) else {
            exportError = DatabaseError.connectionFailed("No active connection").localizedDescription
            return
        }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let columns = selectedTableSchema?.columns.map(\.name) ?? queryResult?.columns ?? []
        guard !columns.isEmpty else {
            exportError = pluginLocalization.string("No data to export.")
            return
        }
        let tableExpr = Self.qualifiedName(for: table, type: config.type)
        let filterWhere = range == .filteredRows ? effectiveWhere(dialect: config.type, columns: selectedTableSchema?.columns ?? []) : nil
        do {
            let total = try await exportRowCount(connection: connection, tableExpr: tableExpr, whereClause: filterWhere)
            guard isCurrentConnection(generation, configId: config.id) else { return }
            if total == 0 {
                try Self.writeExportFile(url: url, format: format, columns: columns, rows: [], tableExpr: tableExpr, dialect: config.type)
                exportProgress = 1
                exportCompleted = true
                return
            }
            try FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            if let header = DataExportWriter.header(format: format, columns: columns) {
                try handle.write(contentsOf: Data(header.utf8))
            }
            let pageSize = 5000
            let keyColumn = exportKeyColumn()
            let filterParams = filterWhere?.params ?? []
            var exported = 0
            var isFirst = true
            var cursor: KeysetCursor?
            var page = 0
            while exported < total {
                try Task.checkCancellation()
                let sql: String
                let params: [DatabaseValue]?
                if let keyColumn {
                    // 单一主键：keyset 游标顺序扫描，避免深 OFFSET 线性扫描。
                    let combined = KeysetPaginator.combineWhere(
                        filterClause: filterWhere?.clause,
                        filterParams: filterParams,
                        cursor: cursor,
                        dialect: config.type,
                        quote: { Self.quoteIdentifier($0, for: config.type) })
                    sql = Self.exportPageSQL(tableExpr: tableExpr, columns: columns, whereClause: combined.clause, orderColumn: keyColumn, ascending: true, limit: pageSize, offset: nil, dialect: config.type)
                    params = combined.params.isEmpty ? nil : combined.params
                } else {
                    sql = Self.exportPageSQL(tableExpr: tableExpr, columns: columns, whereClause: filterWhere?.clause, orderColumn: tableOrderBy?.column, ascending: tableOrderBy?.ascending ?? true, limit: pageSize, offset: page * pageSize, dialect: config.type)
                    params = filterParams.isEmpty ? nil : filterParams
                }
                let result = try await connection.query(sql, params: params)
                guard isCurrentConnection(generation, configId: config.id) else { return }
                guard !result.rows.isEmpty else { break }
                var chunk = ""
                for row in result.rows {
                    chunk += DataExportWriter.row(format: format, columns: columns, row: row, tableExpr: tableExpr, dialect: config.type, isFirst: isFirst)
                    isFirst = false
                }
                try handle.write(contentsOf: Data(chunk.utf8))
                exported += result.rows.count
                exportedRowCount = exported
                exportProgress = min(1, Double(exported) / Double(total))
                if let keyColumn {
                    guard let next = KeysetPaginator.cursor(from: result, column: keyColumn, ascending: true) else { break }
                    cursor = next
                } else {
                    page += 1
                }
                if result.rows.count < pageSize { break }
            }
            if let footer = DataExportWriter.footer(format: format) {
                try handle.write(contentsOf: Data(footer.utf8))
            }
            guard isCurrentConnection(generation, configId: config.id) else { return }
            exportProgress = 1
            exportCompleted = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            guard isCurrentConnection(generation, configId: config.id) else { return }
            if error is CancellationError {
                exportError = pluginLocalization.string("Export cancelled.")
            } else {
                exportError = error.localizedDescription
            }
        }
    }

    /// 导出流式分页可用的单一主键列（keyset 游标）；无单一主键时 nil（降级 OFFSET）。
    private func exportKeyColumn() -> String? {
        guard let schema = selectedTableSchema else { return nil }
        let primaryKey = schema.columns.filter(\.isPrimaryKey).map(\.name)
        guard primaryKey.count == 1 else { return nil }
        return primaryKey[0]
    }

    /// 当前页导出的 SQL 表名：打开表用限定名，编辑器结果用占位名。
    private func exportTableExpr(config: DatabaseConfig) -> String {
        if let table = openTableObject { return Self.qualifiedName(for: table, type: config.type) }
        return Self.quoteIdentifier("query_result", for: config.type)
    }

    private func exportRowCount(
        connection: any DatabaseConnection,
        tableExpr: String,
        whereClause: (clause: String, params: [DatabaseValue])?
    ) async throws -> Int {
        let sql = RowCountEstimator.exactQuery(tableExpr: tableExpr, whereClause: whereClause?.clause)
        let result = try await connection.query(sql, params: whereClause?.params)
        guard let first = result.rows.first?.first else { return 0 }
        switch first {
        case .integer(let v): return v
        case .double(let v): return Int(v)
        case .string(let s): return Int(s) ?? 0
        default: return 0
        }
    }

    private nonisolated static func exportPageSQL(
        tableExpr: String,
        columns: [String],
        whereClause: String?,
        orderColumn: String?,
        ascending: Bool,
        limit: Int,
        offset: Int?,
        dialect: DatabaseType
    ) -> String {
        let cols = columns.map { quoteIdentifier($0, for: dialect) }.joined(separator: ", ")
        var sql = "SELECT \(cols) FROM \(tableExpr)"
        if let whereClause, !whereClause.isEmpty { sql += " WHERE \(whereClause)" }
        if let orderColumn { sql += " ORDER BY \(quoteIdentifier(orderColumn, for: dialect)) \(ascending ? "ASC" : "DESC")" }
        sql += " LIMIT \(limit)"
        if let offset { sql += " OFFSET \(offset)" }
        return sql
    }

    /// 整段写盘（当前页 / 空结果）：行数有限，一次性组装后原子写入。
    private nonisolated static func writeExportFile(
        url: URL,
        format: ExportFormat,
        columns: [String],
        rows: [[DatabaseValue]],
        tableExpr: String,
        dialect: DatabaseType
    ) throws {
        var text = DataExportWriter.header(format: format, columns: columns) ?? ""
        for (index, row) in rows.enumerated() {
            text += DataExportWriter.row(format: format, columns: columns, row: row, tableExpr: tableExpr, dialect: dialect, isFirst: index == 0)
        }
        text += DataExportWriter.footer(format: format) ?? ""
        try Data(text.utf8).write(to: url, options: .atomic)
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
        let filterWhere = effectiveWhere(dialect: config.type, columns: selectedTableSchema?.columns ?? [])
        let useKeyset = keysetAvailable
        let combined = KeysetPaginator.combineWhere(
            filterClause: filterWhere?.clause,
            filterParams: filterWhere?.params ?? [],
            cursor: useKeyset ? keysetCursor : nil,
            dialect: config.type,
            quote: { Self.quoteIdentifier($0, for: config.type) })
        let filterParams: [DatabaseValue]? = combined.params.isEmpty ? nil : combined.params
        if let clause = combined.clause, !clause.isEmpty {
            sql += " WHERE \(clause)"
        }
        if let order = tableOrderBy {
            let col = Self.quoteIdentifier(order.column, for: config.type)
            sql += " ORDER BY \(col) \(order.ascending ? "ASC" : "DESC")"
        }
        if useKeyset {
            // keyset：游标已定位起点，无需 OFFSET。
            sql += " LIMIT \(tablePageSize)"
        } else {
            let offset = tablePage * tablePageSize
            sql += " LIMIT \(tablePageSize) OFFSET \(offset)"
        }

        isLoading = true
        errorMessage = nil
        do {
            let result = try await connection.query(sql, params: filterParams)
            guard isCurrentConnection(generation, configId: config.id),
                  openTableObject?.id == table.id else { return }
            queryResult = result
            // 如果本页空且不是首页，回退到上一页（例如删除后）；keyset 模式由游标定位，不做 OFFSET 回退。
            if result.rows.isEmpty, tablePage > 0, !useKeyset {
                tablePage = max(0, tablePage - 1)
                await loadTablePage()
                isLoading = false
                return
            }
            queryText = sql  // 让 SQL 编辑器可见当前浏览语句
            if gridFindVisible, gridFindScope == .currentPage {
                refreshCurrentPageFindMatches()
            }
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

    /// 后台填充 ``tableRowCount``：无筛选时优先引擎估算（PG reltuples / MySQL
    /// information_schema），估算不可用或带筛选时降级精确 `COUNT(*)`。
    public func refreshTableRowCount() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, let table = openTableObject else { return }
        guard config.type.capabilities.supportsPagination else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let whereClause = effectiveWhere(dialect: config.type, columns: selectedTableSchema?.columns ?? [])

        // 带筛选时估算无法反映过滤后的行数，直接精确计数。
        if whereClause == nil,
           let estimate = RowCountEstimator.estimateQuery(
               for: config.type,
               schema: estimateSchema(for: table, config: config),
               table: table.name) {
            do {
                let result = try await connection.query(estimate.sql, params: estimate.params)
                guard isCurrentConnection(generation, configId: config.id),
                      openTableObject?.id == table.id else { return }
                if let first = result.rows.first?.first,
                   let count = RowCountEstimator.interpretEstimate(first) {
                    tableRowCount = count
                    tableRowCountIsApproximate = true
                    return
                }
            } catch {
                // 估算失败（如权限不足）降级精确计数。
            }
            guard isCurrentConnection(generation, configId: config.id),
                  openTableObject?.id == table.id else { return }
        }
        await runExactRowCount(connection: connection, config: config, table: table, generation: generation, whereClause: whereClause)
    }

    /// 按需精确计数（用户点击「精确计数」时调用），覆盖估算值。
    public func refreshExactRowCount() async {
        let generation = connectionGeneration
        guard let config = selectedConfig, let table = openTableObject else { return }
        guard config.type.capabilities.supportsPagination else { return }
        guard let connection = await manager.getConnection(for: config.id) else { return }
        guard isCurrentConnection(generation, configId: config.id) else { return }
        let whereClause = effectiveWhere(dialect: config.type, columns: selectedTableSchema?.columns ?? [])
        await runExactRowCount(connection: connection, config: config, table: table, generation: generation, whereClause: whereClause)
    }

    private func runExactRowCount(
        connection: any DatabaseConnection,
        config: DatabaseConfig,
        table: DatabaseObject,
        generation: Int,
        whereClause: (clause: String, params: [DatabaseValue])?
    ) async {
        let tableExpr = Self.qualifiedName(for: table, type: config.type)
        let sql = RowCountEstimator.exactQuery(tableExpr: tableExpr, whereClause: whereClause?.clause)
        do {
            let result = try await connection.query(sql, params: whereClause?.params)
            guard isCurrentConnection(generation, configId: config.id),
                  openTableObject?.id == table.id else { return }
            if let first = result.rows.first?.first {
                switch first {
                case .integer(let v): tableRowCount = v
                case .double(let v): tableRowCount = Int(v)
                case .string(let s): tableRowCount = Int(s)
                default: break
                }
                tableRowCountIsApproximate = false
            }
        } catch {
            // 行数查询失败不影响浏览
        }
    }

    /// 估算查询所需的 schema/库名：PG 用 schema（默认 public），MySQL 用库名。
    private func estimateSchema(for table: DatabaseObject, config: DatabaseConfig) -> String? {
        switch config.type {
        case .postgresql: return table.schema ?? "public"
        case .mysql: return table.database ?? config.database
        case .sqlite, .redis: return nil
        }
    }

    public func nextPage() async {
        if keysetAvailable {
            guard let result = queryResult, let order = tableOrderBy,
                  let next = KeysetPaginator.cursor(from: result, column: order.column, ascending: order.ascending) else { return }
            keysetHistory.append(keysetCursor)
            keysetCursor = next
            tablePage += 1
            await loadTablePage()
            return
        }
        tablePage += 1
        await loadTablePage()
    }

    public func prevPage() async {
        if keysetAvailable {
            guard !keysetHistory.isEmpty else { return }
            keysetCursor = keysetHistory.removeLast()
            tablePage = max(0, tablePage - 1)
            await loadTablePage()
            return
        }
        guard tablePage > 0 else { return }
        tablePage -= 1
        await loadTablePage()
    }

    public func setPageSize(_ size: Int) async {
        tablePageSize = max(1, size)
        tablePage = 0
        resetKeyset()
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
        resetKeyset()
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

    // MARK: - 网格复制与粘贴

    /// 当前结果是否有可用于 UPDATE 定位的行键（主键，或 SQLite rowid 别名）。
    public var gridHasRowKey: Bool { !gridKeyColumns.isEmpty }

    /// 当前是否实际启用 keyset 分页（开关开启且按单一主键列排序）。
    public var keysetAvailable: Bool {
        guard useKeysetPagination, let order = tableOrderBy else { return false }
        return KeysetPaginator.isApplicable(orderColumn: order.column, keyColumns: gridKeyColumns)
    }

    /// 重置 keyset 游标与历史（换表 / 改排序 / 改页大小 / 改筛选时调用）。
    private func resetKeyset() {
        keysetCursor = nil
        keysetHistory = []
    }

    /// 开关 keyset 分页：回到首页、清游标并重新加载。
    public func setUseKeysetPagination(_ enabled: Bool) async {
        useKeysetPagination = enabled
        tablePage = 0
        resetKeyset()
        await loadTablePage()
    }

    // MARK: - 网格查找

    /// 展开查找条（⌘F）；若已有查找词则立即刷新匹配。
    public func showGridFind() {
        gridFindVisible = true
        if gridFindScope == .currentPage {
            refreshCurrentPageFindMatches()
        }
    }

    /// 关闭查找条并清除查找词、匹配与服务端查找过滤。
    public func closeGridFind() {
        gridFindVisible = false
        gridFindText = ""
        gridFindMatches = []
        gridFindMatchIndex = 0
        if gridSearchTerm != nil {
            gridSearchTerm = nil
            tablePage = 0
            resetKeyset()
            tableRowCount = nil
            Task { await loadTablePage() }
        }
    }

    /// 重置查找状态（换表 / 关闭浏览时调用）。
    private func resetGridFind() {
        gridFindVisible = false
        gridFindText = ""
        gridFindMatches = []
        gridFindMatchIndex = 0
        gridSearchTerm = nil
    }

    /// 执行查找：当前页仅重算客户端匹配；全量则设置服务端 LIKE 过滤并回到首页重载。
    public func runGridFind() async {
        let term = gridFindText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSearch = gridSearchTerm
        switch gridFindScope {
        case .currentPage:
            gridSearchTerm = nil
        case .allRows:
            gridSearchTerm = term.isEmpty ? nil : term
        }
        if gridSearchTerm != previousSearch {
            tablePage = 0
            resetKeyset()
            tableRowCount = nil
            await loadTablePage()
        }
        refreshCurrentPageFindMatches()
    }

    /// 重算当前页匹配（查找词变化或翻页后调用）；保持活动匹配索引在有效范围。
    public func refreshCurrentPageFindMatches() {
        guard let result = queryResult else {
            gridFindMatches = []
            gridFindMatchIndex = 0
            return
        }
        gridFindMatches = GridFind.matches(columns: result.columns, rows: result.rows, term: gridFindText) { value in
            Self.findDisplayText(value)
        }
        if gridFindMatches.isEmpty {
            gridFindMatchIndex = 0
        } else {
            gridFindMatchIndex = min(gridFindMatchIndex, gridFindMatches.count - 1)
        }
    }

    /// 跳到下一个匹配（循环）。
    public func nextGridFindMatch() {
        guard !gridFindMatches.isEmpty else { return }
        gridFindMatchIndex = (gridFindMatchIndex + 1) % gridFindMatches.count
    }

    /// 跳到上一个匹配（循环）。
    public func prevGridFindMatch() {
        guard !gridFindMatches.isEmpty else { return }
        gridFindMatchIndex = (gridFindMatchIndex - 1 + gridFindMatches.count) % gridFindMatches.count
    }

    /// 查找匹配用的单元格显示文本（与网格渲染一致）。
    static func findDisplayText(_ value: DatabaseValue) -> String {
        switch value {
        case .integer(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .bool(let v): return String(v)
        case .data(let v): return "<BLOB \(v.count) bytes>"
        case .null: return "NULL"
        }
    }

    /// 浏览/计数共用的有效 WHERE：用户筛选 AND 全量查找（若有）。
    /// 查找占位符接在筛选参数之后编号，保证 PostgreSQL `$n` 连续。
    private func effectiveWhere(dialect: DatabaseType, columns: [TableColumn]) -> (clause: String, params: [DatabaseValue])? {
        let filter = tableFilter.buildWhere(dialect: dialect, columns: columns)
        guard let term = gridSearchTerm, !term.isEmpty else { return filter }
        guard let search = GridFind.serverWhere(
            columns: columns,
            term: term,
            dialect: dialect,
            startIndex: filter?.params.count ?? 0,
            quote: { Self.quoteIdentifier($0, for: dialect) }
        ) else { return filter }
        if let filter {
            return ("(\(filter.clause)) AND \(search.clause)", filter.params + search.params)
        }
        return search
    }

    // MARK: - 列布局持久化

    /// 调整某列宽度（钳制后）并持久化。
    public func setGridColumnWidth(_ column: String, width: CGFloat) {
        gridColumnWidths[column] = GridColumnLayout.clampWidth(width)
        persistGridLayout()
    }

    /// 左/右移动某列并持久化新顺序。
    public func moveGridColumn(_ column: String, left: Bool) {
        let columns = queryResult?.columns ?? selectedTableSchema?.columns.map(\.name) ?? []
        guard !columns.isEmpty else { return }
        gridColumnOrder = GridColumnLayout.moved(columns: columns, order: gridColumnOrder.isEmpty ? nil : gridColumnOrder, column: column, left: left)
        persistGridLayout()
    }

    /// 当前表的布局持久化键（连接 + 对象唯一）。
    private var gridLayoutKey: String? {
        guard let config = selectedConfig, let table = openTableObject else { return nil }
        return "DatabaseManager.gridLayout.\(config.id.uuidString).\(table.id)"
    }

    /// 打开表时载入已保存的列宽/列序。
    private func loadGridLayout() {
        gridColumnWidths = [:]
        gridColumnOrder = []
        guard let key = gridLayoutKey,
              let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(GridColumnLayout.Saved.self, from: data) else { return }
        gridColumnWidths = saved.widths
        gridColumnOrder = saved.order
    }

    private func persistGridLayout() {
        guard let key = gridLayoutKey else { return }
        let saved = GridColumnLayout.Saved(widths: gridColumnWidths, order: gridColumnOrder)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private var gridKeyColumns: [String] {
        guard let schema = selectedTableSchema else { return [] }
        let primaryKey = schema.columns.filter(\.isPrimaryKey).map(\.name)
        if !primaryKey.isEmpty { return primaryKey }
        if selectedConfig?.type == .sqlite, queryResult?.columns.contains("rowid") == true {
            return ["rowid"]
        }
        return []
    }

    /// 行级复制文本（JSON/CSV/INSERT/UPDATE）；复制的是显示值（含暂存编辑）。
    public func gridCopyText(rowKind: GridRowCopyKind, row: [DatabaseValue], columns: [String]) -> String? {
        guard let config = selectedConfig, let table = openTableObject else { return nil }
        let tableExpr = Self.qualifiedName(for: table, type: config.type)
        let displayed = displayedRow(row, columns: columns)
        switch rowKind {
        case .json:
            return GridCopyFormat.rowJSON(columns: columns, row: displayed)
        case .csv:
            return GridCopyFormat.rowCSV(columns: columns, row: displayed)
        case .insert:
            return GridCopyFormat.insertSQL(tableExpr: tableExpr, columns: columns, row: displayed, dialect: config.type)
        case .update:
            return GridCopyFormat.updateSQL(
                tableExpr: tableExpr,
                columns: columns,
                row: displayed,
                keyColumns: gridKeyColumns,
                dialect: config.type
            )
        }
    }

    /// 当前页某列全部值的 IN 列表（去重、跳过 NULL）。
    public func gridInListText(column: String) -> String? {
        guard let config = selectedConfig, let result = queryResult,
              result.columns.contains(column) else { return nil }
        let rows = result.rows.map { row in [displayedValue(of: column, row: row, columns: result.columns)] }
        return GridCopyFormat.inList(column: column, columns: [column], rows: rows, dialect: config.type)
    }

    /// 页级复制文本（带表头 CSV / Markdown 表）。
    public func gridPageText(_ kind: GridPageCopyKind) -> String? {
        guard let result = queryResult else { return nil }
        let rows = result.rows.map { displayedRow($0, columns: result.columns) }
        switch kind {
        case .csv:
            return GridCopyFormat.csvWithHeaders(columns: result.columns, rows: rows)
        case .markdown:
            return GridCopyFormat.markdownTable(columns: result.columns, rows: rows)
        }
    }

    /// 粘贴 CSV/JSON 文本为新增行（入变更队列，未保存）。返回暂存行数。
    @discardableResult
    public func gridPasteRows(from text: String) -> Int {
        guard let cm = changeManager, cm.isEditable, let result = queryResult else { return 0 }
        guard let parsed = GridPasteParser.parse(text, columns: result.columns) else {
            errorMessage = pluginLocalization.string("Clipboard does not contain CSV or JSON rows")
            return 0
        }
        for row in parsed {
            let insertId = cm.addInsert()
            for (index, cell) in row.enumerated() where index < result.columns.count {
                let column = result.columns[index]
                switch cell {
                case .unset:
                    continue
                case .null:
                    cm.setInsertColumn(insertId: insertId, column: column, value: .null)
                case .text(let cellText):
                    let value = parseEditedCellValue(cellText, columnType: cm.columnType(of: column), original: nil)
                    cm.setInsertColumn(insertId: insertId, column: column, value: value)
                }
            }
        }
        objectWillChange.send()
        return parsed.count
    }

    private func displayedRow(_ row: [DatabaseValue], columns: [String]) -> [DatabaseValue] {
        guard let cm = changeManager else { return row }
        return columns.map { cm.displayedValue(column: $0, rowValues: row, columns: columns) }
    }

    private func displayedValue(of column: String, row: [DatabaseValue], columns: [String]) -> DatabaseValue {
        if let cm = changeManager {
            return cm.displayedValue(column: column, rowValues: row, columns: columns)
        }
        guard let index = columns.firstIndex(of: column), index < row.count else { return .null }
        return row[index]
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
        resetKeyset()
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

    // MARK: - 密码来源解析与确认闸门

    /// 密码询问请求的展示模型（askEveryTime 来源）。
    public struct PasswordPromptRequest: Identifiable, Sendable {
        public let id = UUID()
        public let connectionName: String
        public let username: String?
    }

    /// 命令确认请求的展示模型（command 来源）。
    public struct CommandConfirmationRequest: Identifiable, Sendable {
        public let id = UUID()
        public let connectionName: String
        public let command: String
    }

    /// 解析连接的有效密码，返回一份密码已就绪的配置副本（原始配置不被修改）。
    ///
    /// - 默认（无 passwordSource）：直接用 config.password（Keychain 已在载入时回填）。
    /// - command：先经用户确认闸门，批准后才本机执行；拒绝或代际失效则中止连接。
    /// - askEveryTime：弹窗询问，密码仅存内存；取消则中止连接。
    /// - file/environment/keychain：经 ``passwordResolver`` 静态求值。
    ///
    /// 安全：解析出的密码只写入返回副本，绝不写回 selectedConfig/已保存配置；命令输出不落日志。
    private func resolvedConnectConfig(for config: DatabaseConfig, generation: Int) async throws -> DatabaseConfig {
        guard let source = config.passwordSource else { return config }
        if source.kind == .command {
            let approved = await requestCommandConfirmation(command: source.command ?? "", connectionName: config.name)
            guard connectionGeneration == generation else { throw DatabaseError.cancelled }
            guard approved else { throw DatabaseError.cancelled }
        }
        let resolved: String?
        if source.kind == .askEveryTime {
            let entered = await requestPasswordPrompt(connectionName: config.name, username: config.username)
            guard connectionGeneration == generation else { throw DatabaseError.cancelled }
            guard let entered else { throw DatabaseError.cancelled }
            resolved = entered
        } else {
            resolved = try await passwordResolver.resolve(source, keychainPassword: config.password)
            guard connectionGeneration == generation else { throw DatabaseError.cancelled }
        }
        var copy = config
        copy.password = resolved
        return copy
    }

    private func requestPasswordPrompt(connectionName: String, username: String?) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            passwordPromptContinuation = continuation
            passwordPrompt = PasswordPromptRequest(connectionName: connectionName, username: username)
        }
    }

    /// 用户对密码询问面板的决定：输入密码继续连接，nil 取消。续体只消费一次，重复调用安全。
    public func resolvePasswordPrompt(_ password: String?) {
        passwordPrompt = nil
        let continuation = passwordPromptContinuation
        passwordPromptContinuation = nil
        continuation?.resume(returning: password)
    }

    private func requestCommandConfirmation(command: String, connectionName: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            commandConfirmationContinuation = continuation
            commandConfirmation = CommandConfirmationRequest(connectionName: connectionName, command: command)
        }
    }

    /// 用户对命令确认弹窗的决定：true 批准执行，false 取消。续体只消费一次，重复调用安全。
    public func resolveCommandConfirmation(_ approved: Bool) {
        commandConfirmation = nil
        let continuation = commandConfirmationContinuation
        commandConfirmationContinuation = nil
        continuation?.resume(returning: approved)
    }

    /// 连接切换/断开时取消仍在挂起的密码询问与命令确认，避免续体泄漏导致连接流程永久挂起。
    private func cancelPendingPasswordRequests() {
        if passwordPromptContinuation != nil { resolvePasswordPrompt(nil) }
        if commandConfirmationContinuation != nil { resolveCommandConfirmation(false) }
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

// MARK: - 多标签查询工作区接线
//
// 活动标签的实时状态由上面的发布属性承载（与表浏览共用），工作区只保存非活动
// 标签的快照。执行方法捕获发起时的 `origin` 标签 id：结果回来时若 origin 仍是
// 活动标签，按既有路径写实时状态（行为与单标签时代完全一致）；否则写进 origin
// 的快照，避免用户中途切标签导致结果串台。防过期 token（executionSequence /
// connectionGeneration）仍在各执行方法内校验。
extension DatabaseViewModel {
    /// 文本编辑后的防抖持久化（仅元数据落盘，结果不持久化）。
    private func scheduleWorkspacePersist() {
        guard !isRestoringTab else { return }
        workspacePersistTask?.cancel()
        workspacePersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.syncActiveSnapshot()
            self.workspace.persist()
        }
    }

    /// 把活动标签的实时状态拷进工作区快照。
    private func syncActiveSnapshot() {
        workspace.updateActive { tab in
            tab.text = queryText
            tab.cursorLocation = editorCursorLocation
            tab.result = queryResult
            tab.multiExecutions = multiExecutions
            tab.selectedExecutionIndex = selectedExecutionIndex
            tab.baseSQL = editorBaseSQL
            tab.baseParams = editorBaseParams
            tab.hasMore = editorHasMore
            tab.fetchedRows = editorFetchedRows
            tab.isLoadingMore = isLoadingMore
            tab.lastBatchRolledBack = lastBatchRolledBack
            tab.errorMessage = errorMessage
            tab.classifiedError = classifiedError
            tab.parameterBindings = parameterBindings
        }
    }

    /// 把某个标签快照载入实时状态（切换/重开/恢复时）。抑制期间的持久化调度。
    private func applyTab(_ tab: QueryTab) {
        isRestoringTab = true
        queryText = tab.text
        editorCursorLocation = tab.cursorLocation
        queryResult = tab.result
        multiExecutions = tab.multiExecutions
        selectedExecutionIndex = tab.selectedExecutionIndex
        editorBaseSQL = tab.baseSQL
        editorBaseParams = tab.baseParams
        editorHasMore = tab.hasMore
        editorFetchedRows = tab.fetchedRows
        isLoadingMore = tab.isLoadingMore
        lastBatchRolledBack = tab.lastBatchRolledBack
        // errorMessage 的 didSet 会在置 nil 时清掉 classifiedError，故先写 errorMessage。
        errorMessage = tab.errorMessage
        classifiedError = tab.classifiedError
        parameterBindings = tab.parameterBindings
        isRestoringTab = false
        refreshParameterNames()
    }

    /// 单语句执行起点：自增序列号并清空上一轮结果/错误/分页。
    private func beginExecution(origin: UUID) -> UInt64 {
        executionSequence += 1
        if origin == workspace.activeTabID {
            errorMessage = nil
            multiExecutions = []
            resetEditorPaging()
            syncActiveSnapshot()
        } else {
            workspace.mutateTab(id: origin) { tab in
                tab.errorMessage = nil
                tab.classifiedError = nil
                tab.multiExecutions = []
                tab.baseSQL = nil
                tab.baseParams = nil
                tab.hasMore = false
                tab.fetchedRows = 0
            }
        }
        return executionSequence
    }

    /// 单语句成功结果回写（读/写共用）。
    private func commitQueryResult(
        _ result: QueryResult, origin: UUID, baseSQL: String?, baseParams: [DatabaseValue]?, fetchedRows: Int, hasMore: Bool
    ) {
        if origin == workspace.activeTabID {
            queryResult = result
            editorBaseSQL = baseSQL
            editorBaseParams = baseParams
            editorFetchedRows = fetchedRows
            editorHasMore = hasMore
            syncActiveSnapshot()
        } else {
            workspace.mutateTab(id: origin) { tab in
                tab.result = result
                tab.baseSQL = baseSQL
                tab.baseParams = baseParams
                tab.fetchedRows = fetchedRows
                tab.hasMore = hasMore
            }
        }
    }

    /// 错误回写：分类后同步到活动标签实时状态或 origin 快照。
    private func commitError(_ error: any Error, origin: UUID) {
        let classified = DatabaseErrorClassifier.classify(error)
        if origin == workspace.activeTabID {
            classifiedError = classified
            errorMessage = classified.detail
            syncActiveSnapshot()
        } else {
            workspace.mutateTab(id: origin) { tab in
                tab.classifiedError = classified
                tab.errorMessage = classified.detail
            }
        }
    }

    /// 单语句执行收尾：复位全局加载态与运行标签标记。
    private func finishExecution(origin: UUID) {
        isLoading = false
        runningTabID = nil
        if origin == workspace.activeTabID { syncActiveSnapshot() }
    }

    /// 增量加载下一页：把新行追加到 origin 的结果尾部。
    private func appendMoreRows(_ result: QueryResult, origin: UUID, pageSize: Int) {
        if origin == workspace.activeTabID {
            if var current = queryResult {
                current.rows.append(contentsOf: result.rows)
                queryResult = current
            }
            editorFetchedRows += result.rows.count
            editorHasMore = result.rows.count >= pageSize
        } else {
            workspace.mutateTab(id: origin) { tab in
                if var current = tab.result {
                    current.rows.append(contentsOf: result.rows)
                    tab.result = current
                }
                tab.fetchedRows += result.rows.count
                tab.hasMore = result.rows.count >= pageSize
            }
        }
    }

    /// 批量执行起点：清空上一轮多结果/错误/分页（序列号由调用方自增）。
    private func clearForBatch(origin: UUID) {
        if origin == workspace.activeTabID {
            errorMessage = nil
            lastBatchRolledBack = false
            multiExecutions = []
            queryResult = nil
            resetEditorPaging()
            syncActiveSnapshot()
        } else {
            workspace.mutateTab(id: origin) { tab in
                tab.errorMessage = nil
                tab.classifiedError = nil
                tab.lastBatchRolledBack = false
                tab.multiExecutions = []
                tab.result = nil
                tab.baseSQL = nil
                tab.baseParams = nil
                tab.hasMore = false
                tab.fetchedRows = 0
            }
        }
    }

    /// 批量执行结果回写。
    private func commitBatch(
        _ executions: [StatementExecution], lastSuccess: QueryResult?, rolledBack: Bool, origin: UUID
    ) {
        if origin == workspace.activeTabID {
            multiExecutions = executions
            queryResult = lastSuccess
            selectedExecutionIndex = 0
            lastBatchRolledBack = rolledBack
            syncActiveSnapshot()
        } else {
            workspace.mutateTab(id: origin) { tab in
                tab.multiExecutions = executions
                tab.result = lastSuccess
                tab.selectedExecutionIndex = 0
                tab.lastBatchRolledBack = rolledBack
            }
        }
    }

    // MARK: 标签管理（UI 入口）

    /// 新建查询标签并激活。
    public func newQueryTab() {
        syncActiveSnapshot()
        workspace.newTab()
        applyTab(workspace.activeTab)
        workspace.persist()
    }

    /// 切换到指定标签（先把当前实时状态存回旧活动快照）。
    public func selectQueryTab(id: UUID) {
        guard id != workspace.activeTabID else { return }
        syncActiveSnapshot()
        workspace.selectTab(id: id)
        applyTab(workspace.activeTab)
        workspace.persist()
    }

    /// 关闭标签：脏标签先弹确认（``pendingCloseTabID``），干净标签直接关。
    public func closeQueryTab(id: UUID) {
        syncActiveSnapshot()
        if workspace.isDirty(id: id) {
            pendingCloseTabID = id
            return
        }
        performCloseTab(id: id)
    }

    /// 用户确认关闭脏标签。
    public func confirmClosePendingTab() {
        guard let id = pendingCloseTabID else { return }
        pendingCloseTabID = nil
        performCloseTab(id: id)
    }

    /// 用户取消关闭。
    public func cancelClosePendingTab() {
        pendingCloseTabID = nil
    }

    private func performCloseTab(id: UUID) {
        let wasActive = (id == workspace.activeTabID)
        workspace.closeTab(id: id)
        if wasActive { applyTab(workspace.activeTab) }
        workspace.persist()
    }

    /// 重命名标签。
    public func renameQueryTab(id: UUID, title: String) {
        workspace.renameTab(id: id, title: title)
        workspace.persist()
    }

    /// 重开最近关闭的标签并激活。
    public func reopenLastClosedTab() {
        syncActiveSnapshot()
        guard let tab = workspace.reopenLastClosed() else { return }
        applyTab(tab)
        workspace.persist()
    }

    /// 切换到下一个查询标签（循环回绕）；仅一个标签时无操作。
    public func selectNextQueryTab() {
        let count = workspace.tabs.count
        guard count > 1 else { return }
        selectQueryTab(id: workspace.tabs[(workspace.activeIndex + 1) % count].id)
    }

    /// 切换到上一个查询标签（循环回绕）；仅一个标签时无操作。
    public func selectPreviousQueryTab() {
        let count = workspace.tabs.count
        guard count > 1 else { return }
        selectQueryTab(id: workspace.tabs[(workspace.activeIndex - 1 + count) % count].id)
    }

    /// 切换到指定位置的标签（0 起，对应 ⌘1…⌘9）；越界忽略。
    public func selectQueryTab(index: Int) {
        guard workspace.tabs.indices.contains(index) else { return }
        selectQueryTab(id: workspace.tabs[index].id)
    }
}

// MARK: - SQL 文件往返（P3-6）
//
// 打开 .sql 为文件标签、⌘S 写回、外部变更检测 → Reload / Save As 横幅。
// 面板（NSOpenPanel/NSSavePanel）与磁盘逻辑分离：逻辑方法接收 URL，便于无头测试。
extension DatabaseViewModel {
    /// 外部变更轮询：每 2s 探测一次，仅在已连接且活动标签关联文件时实际读取磁盘。
    func startFileWatch() {
        fileWatchTask?.cancel()
        fileWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                if self.isConnected, self.workspace.activeTab.fileURL != nil {
                    self.refreshExternalChangeState()
                }
            }
        }
    }

    /// 打开 .sql 文件为新标签并激活（切回编辑器视图）。读取失败走统一错误入口。
    public func openSQLFile(at url: URL) {
        do {
            let text = try SQLFileStore.read(url)
            let baseline = SQLFileStore.snapshot(of: url)
            syncActiveSnapshot()
            openTableObject = nil
            let id = workspace.newTab(title: url.lastPathComponent, text: text)
            workspace.mutateTab(id: id) { tab in
                tab.fileURL = url
                tab.fileBaseline = baseline
                tab.savedText = text
            }
            applyTab(workspace.activeTab)
            sqlFileConflict = nil
            workspace.persist()
        } catch {
            presentError(error)
        }
    }

    /// ⌘S：有关联文件则写回，否则弹 Save As 面板。
    public func saveActiveSQLFile() {
        syncActiveSnapshot()
        guard let url = workspace.activeTab.fileURL else {
            presentSaveSQLPanel()
            return
        }
        writeActiveSQLFile(to: url)
    }

    /// Save As：写入新位置并把标签重新关联到该文件（原文件不动）。
    public func saveActiveSQLFile(as url: URL) {
        syncActiveSnapshot()
        writeActiveSQLFile(to: url)
    }

    func writeActiveSQLFile(to url: URL) {
        do {
            try SQLFileStore.write(queryText, to: url)
            let baseline = SQLFileStore.snapshot(of: url)
            let retitle = workspace.activeTab.fileURL != url
            workspace.updateActive { tab in
                tab.fileURL = url
                tab.fileBaseline = baseline
                tab.savedText = queryText
                if retitle { tab.title = url.lastPathComponent }
            }
            sqlFileConflict = nil
            workspace.persist()
        } catch {
            presentError(error)
        }
    }

    /// Reload：用磁盘内容覆盖编辑器，复位脏标记与基线（丢弃本地未保存改动）。
    public func reloadActiveSQLFile() {
        guard let url = workspace.activeTab.fileURL else { return }
        do {
            let text = try SQLFileStore.read(url)
            let baseline = SQLFileStore.snapshot(of: url)
            queryText = text
            workspace.updateActive { tab in
                tab.text = text
                tab.savedText = text
                tab.fileBaseline = baseline
            }
            sqlFileConflict = nil
            workspace.persist()
        } catch {
            presentError(error)
        }
    }

    /// Keep Editing：承认当前磁盘版本为新基线，保留编辑器内容继续编辑；
    /// 后续真正的外部变更仍会再次触发横幅。
    public func dismissSQLFileConflict() {
        if let url = workspace.activeTab.fileURL {
            let baseline = SQLFileStore.snapshot(of: url)
            workspace.updateActive { $0.fileBaseline = baseline }
            workspace.persist()
        }
        sqlFileConflict = nil
    }

    /// 探测活动标签文件的外部变更并刷新冲突状态。
    /// 每次读取磁盘快照、以内容哈希为准（见 ``SQLFileChangeDetector``）：
    /// mtime 在本文件系统上可能因快速写入或属性缓存而不变，故不能用它跳过读取。
    public func refreshExternalChangeState() {
        guard let url = workspace.activeTab.fileURL, let baseline = workspace.activeTab.fileBaseline else {
            sqlFileConflict = nil
            return
        }
        let current = SQLFileStore.snapshot(of: url)
        let change = SQLFileChangeDetector.classify(baseline: baseline, current: current)
        if change == .unchanged {
            sqlFileConflict = nil
        } else {
            sqlFileConflict = SQLFileConflict(
                url: url,
                change: change,
                isDirty: queryText != workspace.activeTab.savedText
            )
        }
    }

    // MARK: 文件面板（AppKit）

    public func presentOpenSQLPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let sqlType = UTType(filenameExtension: "sql") {
            panel.allowedContentTypes = [sqlType]
        }
        panel.message = pluginLocalization.string("Open SQL File…")
        if panel.runModal() == .OK, let url = panel.url {
            openSQLFile(at: url)
        }
    }

    public func presentSaveSQLPanel() {
        let panel = NSSavePanel()
        if let sqlType = UTType(filenameExtension: "sql") {
            panel.allowedContentTypes = [sqlType]
        }
        panel.nameFieldStringValue = workspace.activeTab.fileURL?.lastPathComponent ?? "query.sql"
        if let dir = workspace.activeTab.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        panel.message = pluginLocalization.string("Save As…")
        if panel.runModal() == .OK, let url = panel.url {
            saveActiveSQLFile(as: url)
        }
    }
}

// MARK: - 结构化 SQL 诊断（P3-7）

extension DatabaseViewModel {
    /// 重新扫描当前编辑器文本的结构化诊断；超大文档降级时清空（与高亮/折叠口径一致）。
    /// 由 `queryText.didSet` 驱动：键入、切换标签、打开/重载文件都会触发。
    func refreshSQLDiagnostics() {
        if EditorDocumentGuard.isLargeDocument(queryText) {
            if !sqlDiagnostics.isEmpty { sqlDiagnostics = [] }
            return
        }
        let scanned = SQLStructuralDiagnostics.scan(queryText)
        if scanned != sqlDiagnostics { sqlDiagnostics = scanned }
    }

    /// 诊断条点击跳转：把编辑器选区移动到诊断范围，Host 经选区绑定应用并滚动到可见。
    public func jumpToSQLDiagnostic(_ diagnostic: SQLStructuralDiagnostic) {
        editorCursorLocation = diagnostic.range.location
        editorSelectionRange = diagnostic.range
    }

    /// Host 诊断 Provider 的纯扫描入口：文本 → 编辑器标记（不触碰 ViewModel 状态）。
    nonisolated static func embeddedSQLDiagnostics(_ text: String) -> [EditorEmbeddedDiagnostic] {
        guard !EditorDocumentGuard.isLargeDocument(text) else { return [] }
        return SQLStructuralDiagnostics.scan(text).map { diagnostic in
            EditorEmbeddedDiagnostic(
                range: diagnostic.range,
                severity: diagnostic.severity == .error ? .error : .warning
            )
        }
    }
}
