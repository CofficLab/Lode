import Foundation
import Combine

/// 查询标签工作区：管理标签序列、活动标签、最近关闭栈与会话持久化。
///
/// 纯状态机（新建/关闭/重命名/切换/重开/脏标记/持久化往返），不依赖 UI。
/// 活动标签的实时编辑/结果状态由 ``DatabaseViewModel`` 承载，切换前后由 VM
/// 通过 ``updateActive(_:)`` / ``activeTab`` 与本store同步；非活动标签的迟到执行
/// 结果由 VM 经 ``mutateTab(id:_:)`` 路由进对应快照，避免串结果。
@MainActor
public final class QueryWorkspaceStore: ObservableObject {
    @Published public private(set) var tabs: [QueryTab] = []
    @Published public private(set) var activeTabID: UUID = UUID()
    @Published public private(set) var recentlyClosed: [QueryTab] = []

    /// 是否从磁盘恢复过会话（VM 据此决定恢复活动标签还是用默认编辑器文本播种）。
    public private(set) var loadedFromDisk = false

    private let defaults: UserDefaults
    private let defaultsKey = "DatabaseManager.queryWorkspace"
    private let recentlyClosedCap = 10

    public init(defaults: UserDefaults = .standard, loadPersisted: Bool = true) {
        self.defaults = defaults
        if loadPersisted {
            load()
            if tabs.isEmpty {
                let tab = QueryTab(title: "Query 1")
                tabs = [tab]
                activeTabID = tab.id
            }
        }
    }

    // MARK: - 访问

    public var activeIndex: Int {
        // 谓词只捕获局部值：捕获 self 的隔离闭包经 firstIndex 调用时会插入
        // MainActor.shared 动态隔离检查，其懒初始化争用曾让主线程空转数秒。
        let id = activeTabID
        return tabs.firstIndex { $0.id == id } ?? 0
    }

    /// 是否存在文件关联标签；供外部变更轮询在做任何活动标签计算前廉价短路。
    public var hasFileBackedTab: Bool {
        tabs.contains { $0.fileURL != nil }
    }

    public var activeTab: QueryTab {
        get { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : QueryTab(title: "Query") }
        set {
            guard tabs.indices.contains(activeIndex) else { return }
            tabs[activeIndex] = newValue
        }
    }

    public func tab(id: UUID) -> QueryTab? {
        tabs.first { $0.id == id }
    }

    public func isDirty(id: UUID) -> Bool {
        tab(id: id)?.isDirty ?? false
    }

    // MARK: - 状态机

    /// 新建标签（插在活动标签之后）并激活，返回新 id。
    @discardableResult
    public func newTab(title: String? = nil, text: String = "") -> UUID {
        let name = title ?? "Query \(tabs.count + 1)"
        let tab = QueryTab(title: name, text: text)
        let insertAt = min(activeIndex + 1, tabs.count)
        tabs.insert(tab, at: insertAt)
        activeTabID = tab.id
        return tab.id
    }

    /// 切换活动标签（调用方负责先把实时状态同步进旧活动快照）。
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// 关闭标签：推入最近关闭栈；若关闭的是活动标签则激活相邻标签。
    /// 永不空：关掉最后一个时补一个空标签。返回关闭后的活动 id。
    @discardableResult
    public func closeTab(id: UUID) -> UUID {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return activeTabID }
        let removed = tabs.remove(at: index)
        recentlyClosed.insert(removed, at: 0)
        if recentlyClosed.count > recentlyClosedCap {
            recentlyClosed.removeLast(recentlyClosed.count - recentlyClosedCap)
        }
        if tabs.isEmpty {
            let fresh = QueryTab(title: "Query 1")
            tabs = [fresh]
            activeTabID = fresh.id
        } else if activeTabID == id {
            let neighbor = min(index, tabs.count - 1)
            activeTabID = tabs[neighbor].id
        }
        return activeTabID
    }

    public func renameTab(id: UUID, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].title = trimmed.isEmpty ? tabs[index].title : trimmed
    }

    /// 重开最近关闭的标签（插在活动标签之后并激活）；无则返回 nil。
    @discardableResult
    public func reopenLastClosed() -> QueryTab? {
        guard !recentlyClosed.isEmpty else { return nil }
        var tab = recentlyClosed.removeFirst()
        tab.savedText = tab.text
        let insertAt = min(activeIndex + 1, tabs.count)
        tabs.insert(tab, at: insertAt)
        activeTabID = tab.id
        return tab
    }

    // MARK: - 快照同步

    public func updateActive(_ mutate: (inout QueryTab) -> Void) {
        guard tabs.indices.contains(activeIndex) else { return }
        mutate(&tabs[activeIndex])
    }

    public func mutateTab(id: UUID, _ mutate: (inout QueryTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tabs[index])
    }

    /// 标记某标签文本已保存（脏标记复位）。
    public func markSaved(id: UUID) {
        mutateTab(id: id) { $0.savedText = $0.text }
    }

    /// 连接切换/断开后清空所有标签的运行时结果（结果归属旧连接），保留文本。
    public func clearAllResults() {
        for index in tabs.indices {
            tabs[index].result = nil
            tabs[index].multiExecutions = []
            tabs[index].selectedExecutionIndex = 0
            tabs[index].baseSQL = nil
            tabs[index].baseParams = nil
            tabs[index].hasMore = false
            tabs[index].fetchedRows = 0
            tabs[index].isLoadingMore = false
            tabs[index].lastBatchRolledBack = false
            tabs[index].errorMessage = nil
            tabs[index].classifiedError = nil
        }
    }

    // MARK: - 持久化

    /// 把当前标签序列（仅元数据）写入磁盘。调用方须先把活动标签实时状态同步进快照。
    public func persist() {
        let dto = PersistedQueryWorkspace(
            tabs: tabs.map {
                PersistedQueryTab(
                    id: $0.id,
                    title: $0.title,
                    text: $0.text,
                    cursorLocation: $0.cursorLocation,
                    selectedExecutionIndex: $0.selectedExecutionIndex,
                    fileURL: $0.fileURL,
                    fileBaseline: $0.fileBaseline
                )
            },
            activeTabID: activeTabID
        )
        guard let data = try? JSONEncoder().encode(dto) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// 从磁盘恢复标签序列；结果状态不持久化，恢复后为空。
    public func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let dto = try? JSONDecoder().decode(PersistedQueryWorkspace.self, from: data),
              !dto.tabs.isEmpty else { return }
        loadedFromDisk = true
        tabs = dto.tabs.map {
            QueryTab(
                id: $0.id,
                title: $0.title,
                text: $0.text,
                savedText: $0.text,
                cursorLocation: $0.cursorLocation,
                selectedExecutionIndex: $0.selectedExecutionIndex,
                fileURL: $0.fileURL,
                fileBaseline: $0.fileBaseline
            )
        }
        if let active = dto.activeTabID, tabs.contains(where: { $0.id == active }) {
            activeTabID = active
        } else {
            activeTabID = tabs[0].id
        }
    }
}