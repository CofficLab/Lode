import Foundation

/// 一个查询标签页的完整状态快照。
///
/// 文本/标题/光标持久化到磁盘（重启恢复）；结果与分页等运行时状态仅留在内存，
/// 在标签切换时随快照保存/恢复，避免把可能含敏感数据的查询结果落盘。
/// 活动标签的实时状态由 ``DatabaseViewModel`` 的发布属性承载，切换时与本快照同步。
public struct QueryTab: Identifiable {
    public let id: UUID
    public var title: String
    public var text: String
    /// 上次持久化时的文本；``isDirty`` 据此判断是否有未保存改动。
    public var savedText: String
    public var cursorLocation: Int

    public var result: QueryResult?
    public var multiExecutions: [StatementExecution]
    public var selectedExecutionIndex: Int
    public var baseSQL: String?
    public var baseParams: [DatabaseValue]?
    public var hasMore: Bool
    public var fetchedRows: Int
    public var isLoadingMore: Bool
    public var lastBatchRolledBack: Bool
    public var errorMessage: String?
    public var classifiedError: ClassifiedDatabaseError?
    /// 命名参数面板绑定值；仅内存保存（可能含敏感值），随标签切换保存/恢复。
    public var parameterBindings: [String: QueryParameterBinding]
    /// 关联的 .sql 文件（nil 表示纯内存查询标签）。随会话持久化。
    public var fileURL: URL?
    /// 打开/写回时记录的磁盘基线，用于外部变更检测。随会话持久化。
    public var fileBaseline: SQLFileSnapshot?

    public var isDirty: Bool { text != savedText }
    public var isFileBacked: Bool { fileURL != nil }

    public init(
        id: UUID = UUID(),
        title: String,
        text: String = "",
        savedText: String? = nil,
        cursorLocation: Int = NSNotFound,
        result: QueryResult? = nil,
        multiExecutions: [StatementExecution] = [],
        selectedExecutionIndex: Int = 0,
        baseSQL: String? = nil,
        baseParams: [DatabaseValue]? = nil,
        hasMore: Bool = false,
        fetchedRows: Int = 0,
        isLoadingMore: Bool = false,
        lastBatchRolledBack: Bool = false,
        errorMessage: String? = nil,
        classifiedError: ClassifiedDatabaseError? = nil,
        parameterBindings: [String: QueryParameterBinding] = [:],
        fileURL: URL? = nil,
        fileBaseline: SQLFileSnapshot? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.savedText = savedText ?? text
        self.cursorLocation = cursorLocation
        self.result = result
        self.multiExecutions = multiExecutions
        self.selectedExecutionIndex = selectedExecutionIndex
        self.baseSQL = baseSQL
        self.baseParams = baseParams
        self.hasMore = hasMore
        self.fetchedRows = fetchedRows
        self.isLoadingMore = isLoadingMore
        self.lastBatchRolledBack = lastBatchRolledBack
        self.errorMessage = errorMessage
        self.classifiedError = classifiedError
        self.parameterBindings = parameterBindings
        self.fileURL = fileURL
        self.fileBaseline = fileBaseline
    }

    /// 自动标题：取首行非空文本预览，空文本回退到给定默认名。
    public static func autoTitle(for text: String, fallback: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
    }
}

/// 标签页的磁盘持久化形态（仅元数据，不含结果）。
struct PersistedQueryTab: Codable {
    let id: UUID
    var title: String
    var text: String
    var cursorLocation: Int
    var selectedExecutionIndex: Int
    var fileURL: URL?
    var fileBaseline: SQLFileSnapshot?
}

/// 工作区持久化形态：标签序列 + 活动标签 id。
struct PersistedQueryWorkspace: Codable {
    var tabs: [PersistedQueryTab]
    var activeTabID: UUID?
}