import ProviderEditor
import KernelCore
import ProviderActivityBar
import ProviderChatSection
import ProviderDocsView
import ProviderContentView
import ProviderExternalFile
import ProviderLifecycleHooks
import ProviderRailView
import ProviderRootView
import ProviderSettingView
import ProviderStorage
import ProviderToolbar
import ProviderToolManager
import SwiftUI
import LumiLoggingKit
struct DatabaseManagerPluginSupport {
    /// 共享诊断日志：debug 级受设置开关门控，info/warning/error 始终写出，
    /// 所有消息写出前经 ``LogRedactor`` 脱敏。由 ``DatabaseViewModel`` 按设置同步开关。
    nonisolated static let debugLog = PluginDebugLog()
}

/// DatabaseManager 的 KernelCore 入口，复用既有数据库连接、查询与 SQL 编辑体验。
@MainActor
public final class DatabaseManagerPlugin: SuperPlugin, SuperLog {
    public let id = "com.coffic.lumi.plugin.database-manager"
    public let order = 750
    public let dependencies = ["com.coffic.lumi.plugin.editor-host"]
    public let metadata = PluginMetadata(
        id: "com.coffic.lumi.plugin.database-manager",
        name: pluginLocalization.string("Database"),
        description: pluginLocalization.string("Database connections, SQL queries, schema inspection, and data editing."),
        category: .project,
        stage: .preview,
        policy: .disabledByDefault
    )

    public static let railTabID = "com.coffic.lumi.plugin.database-manager.sidebar"

    private let viewModel: DatabaseViewModel
    private var lifecycleHookHandle: (any LifecycleHookHandle)?

    /// - Parameter loadSavedConfigs: UI 测试隔离时传 `false`，跳过真实
    ///   UserDefaults/Keychain 读取（宿主进程里会触发钥匙串授权弹窗并挂起启动）。
    public init(loadSavedConfigs: Bool = true) {
        viewModel = DatabaseViewModel(loadSavedConfigs: loadSavedConfigs)
    }

    public func onRegister(kernel: KernelCoreContainer) throws {
        if let docs = kernel.resolveProvider((any DocsViewProviding).self) {
            docs.addAbout(DocsEntry(id: id, name: metadata.name) { AboutView() })
            docs.addManual(DocsEntry(id: id, name: metadata.name) { DatabaseManagerManualView() })
        }
    }

    public func onBoot(kernel: KernelCoreContainer) throws {
        viewModel.embeddedEditorProvider = kernel.resolveProvider(EditorEmbeddedEditorProviding.self)
        try installEditorContributions(kernel: kernel)
        lifecycleHookHandle?.cancel()
        let contextHook = DatabaseAgentContextHook()
        lifecycleHookHandle = kernel.resolveProvider((any LifecycleHooksProviding).self)?
            .addWillSendToLLMHook { context in
                contextHook.apply(to: context)
            }
        let contentView = kernel.resolveProvider((any ContentViewProviding).self)
        let chat = kernel.resolveProvider((any ChatSectionProviding).self)
        let railView = kernel.resolveProvider((any RailViewProviding).self)
        let rootView = kernel.resolveProvider((any RootViewProviding).self)
        let toolbar = kernel.resolveProvider((any ToolbarProviding).self)
        let pluginID = id
        let railWidthStore = kernel
            .resolveProvider((any StorageProviding).self)
            .map { storage in
                FileRailViewWidthStore(
                    fileURL: storage
                        .pluginDataDirectory(for: pluginID)
                        .appendingPathComponent("rail-view-width.plist", isDirectory: false)
                )
            }
        let chatWidthStore = kernel
            .resolveProvider((any StorageProviding).self)
            .map { storage in
                FileChatSectionWidthStore(
                    fileURL: storage
                        .pluginDataDirectory(for: pluginID)
                        .appendingPathComponent("chat-section-width.plist", isDirectory: false)
                )
            }
        railView?.addTabs([
            RailTabItem(
                id: Self.railTabID,
                category: .project,
                title: metadata.name,
                systemImage: "cylinder.split.1x2",
                order: order
            ) {
                SidebarView(viewModel: self.viewModel)
            },
        ])
        kernel.resolveProvider((any ActivityBarProviding).self)?.addItems([
            ActivityBarItem(
                id: "\(id).entry",
                title: metadata.name,
                systemImage: "cylinder.split.1x2",
                order: order,
                ownerPluginID: id
            ) { state in
                if state == .activated {
                    DatabaseSQLProposalRuntime.shared.activate(viewModel: self.viewModel)
                    toolbar?.setVisibleCategories([.global, .chat])
                    railView?.setVisibleTabID(Self.railTabID)
                    rootView?.setRailViewVisible(railView?.hasVisibleTabs ?? false)
                    railView?.activateWidthProfile(
                        ownerID: pluginID,
                        recommended: RailViewWidth(minWidth: 260, idealWidth: 320, maxWidth: 460),
                        store: railWidthStore
                    )
                    chat?.setVisible(true)
                    chat?.setContextActive(true)
                    chat?.setActiveContext(.defaultChat)
                    chat?.activateWidthProfile(
                        ownerID: pluginID,
                        recommended: .standard,
                        store: chatWidthStore
                    )
                    rootView?.setContentHeaderViewHidden(true)
                    contentView?.setContentView(
                        AnyView(DatabaseManagerV2Workspace(viewModel: self.viewModel))
                    )
                    toolbar?.addToolbarItems([
                        ToolbarItem(id: "\(self.id).title", title: self.metadata.name, placement: .center, category: .global, order: 0) {
                            Text(self.metadata.name).font(.headline)
                        },
                    ])
                } else {
                    DatabaseSQLProposalRuntime.shared.deactivate(viewModel: self.viewModel)
                    toolbar?.setVisibleCategories(Set(ToolbarItemCategory.allCases))
                    railView?.setVisibleCategories(Set(RailViewCategory.allCases))
                    rootView?.setRailViewVisible(railView?.hasVisibleTabs ?? false)
                    railView?.deactivateWidthProfile(ownerID: pluginID)
                    chat?.deactivateWidthProfile(ownerID: pluginID)
                    chat?.setContextActive(false)
                    chat?.setActiveContext(nil)
                    chat?.setVisible(false)
                    rootView?.setContentHeaderViewHidden(false)
                    toolbar?.removeToolbarItems(ids: ["\(self.id).title"])
                }
            },
        ])
        kernel.resolveProvider((any ExternalFileOpening).self)?.registerHandler(pluginID: id) { url in
            self.openSQLiteDatabase(url)
        }
        let tools = kernel.resolveProvider((any ToolManagerProviding).self)
        tools?.add(DatabaseListConnectionsV2Tool(), pluginID: id)
        tools?.add(DatabaseDescribeSchemaV2Tool(), pluginID: id)
        tools?.add(DatabaseReadonlyQueryV2Tool(), pluginID: id)
        tools?.add(DatabaseSampleTableV2Tool(), pluginID: id)
        tools?.add(DatabaseProposeSQLV2Tool(), pluginID: id)
        kernel.resolveProvider((any SettingViewProviding).self)?.addEntries([
            SettingEntryItem(
                id: "\(id).settings",
                title: metadata.name,
                systemImage: "cylinder.split.1x2",
                order: order
            ) {
                DatabaseSettingsView(viewModel: self.viewModel)
            },
        ])
    }

    public func onShutdown(kernel: KernelCoreContainer) throws {
        lifecycleHookHandle?.cancel()
        lifecycleHookHandle = nil
        DatabaseSQLProposalRuntime.shared.deactivate(viewModel: viewModel)
        try withdrawEditorContributions(kernel: kernel)
        let activityBar = kernel.resolveProvider((any ActivityBarProviding).self)
        let wasActive = activityBar?.activeItemID == "\(id).entry"
        activityBar?.removeItems(ids: ["\(id).entry"])
        if wasActive {
            kernel.resolveProvider((any RailViewProviding).self)?.deactivateWidthProfile(ownerID: id)
            kernel.resolveProvider((any RailViewProviding).self)?.setVisibleCategories(Set(RailViewCategory.allCases))
            let chat = kernel.resolveProvider((any ChatSectionProviding).self)
            chat?.deactivateWidthProfile(ownerID: id)
            chat?.setContextActive(false)
            chat?.setActiveContext(nil)
            chat?.setVisible(false)
            kernel.resolveProvider((any RootViewProviding).self)?.setContentHeaderViewHidden(false)
        }
        kernel.resolveProvider((any RailViewProviding).self)?.removeTabs(ids: [Self.railTabID])
        if wasActive {
            let railView = kernel.resolveProvider((any RailViewProviding).self)
            kernel.resolveProvider((any RootViewProviding).self)?.setRailViewVisible(railView?.hasVisibleTabs ?? false)
        }
        kernel.resolveProvider((any ContentViewProviding).self)?.setContentView(nil)
        kernel.resolveProvider((any ToolbarProviding).self)?.removeToolbarItems(ids: ["\(id).title"])
        kernel.resolveProvider((any ExternalFileOpening).self)?.unregisterHandlers(pluginID: id)
        let tools = kernel.resolveProvider((any ToolManagerProviding).self)
        tools?.remove(id: DatabaseListConnectionsV2Tool.toolName)
        tools?.remove(id: DatabaseDescribeSchemaV2Tool.toolName)
        tools?.remove(id: DatabaseReadonlyQueryV2Tool.toolName)
        tools?.remove(id: DatabaseSampleTableV2Tool.toolName)
        tools?.remove(id: DatabaseProposeSQLV2Tool.toolName)
        kernel.resolveProvider((any SettingViewProviding).self)?.removeEntries(ids: ["\(id).settings"])
        viewModel.embeddedEditorProvider = nil
    }

    public func onEnable(kernel: KernelCoreContainer) async throws {
        try installEditorContributions(kernel: kernel)
        viewModel.embeddedEditorProvider = kernel.resolveProvider(EditorEmbeddedEditorProviding.self)
    }

    public func onDisable(kernel: KernelCoreContainer) async throws {
        try withdrawEditorContributions(kernel: kernel)
        viewModel.embeddedEditorProvider = nil
    }

    public func onUnregister(kernel: KernelCoreContainer) throws {
        kernel.resolveProvider((any DocsViewProviding).self)?.removeEntries(id: id)
    }

    private func installEditorContributions(kernel: KernelCoreContainer) throws {
        guard let editor = kernel.resolveProvider(EditorProviding.self) else {
            throw KernelCoreError.providerNotRegistered(type: EditorProviding.self)
        }
        let bundle = EditorContributionBundle(
            pluginID: id,
            languages: [
                EditorLanguageContribution(
                    language: DatabaseSQLLanguageSupport.descriptor,
                    grammar: DatabaseSQLGrammarProvider()
                ),
            ]
        )
        try editor.extensions.installBundle(for: id, with: bundle.stamped(pluginID: id, generation: 1))
    }

    private func withdrawEditorContributions(kernel: KernelCoreContainer) throws {
        guard let editor = kernel.resolveProvider(EditorProviding.self) else { return }
        try editor.extensions.installBundle(for: id, with: nil)
    }

    private func openSQLiteDatabase(_ url: URL) -> Bool {
        guard ["sqlite", "sqlite3", "db"].contains(url.pathExtension.lowercased()) else { return false }
        let path = url.path
        let config = viewModel.configs.first(where: { $0.type == .sqlite && $0.database == path })
            ?? DatabaseConfig(name: url.deletingPathExtension().lastPathComponent, type: .sqlite, database: path)
        if !viewModel.configs.contains(where: { $0.id == config.id }) {
            viewModel.addConfig(config)
        }
        Task { await viewModel.connect(config: config) }
        return true
    }
}

@MainActor
private struct DatabaseManagerV2Workspace: View {
    @ObservedObject var viewModel: DatabaseViewModel

    var body: some View {
        DatabaseWorkspaceView(viewModel: viewModel)
            .frame(minWidth: 640)
    }
}
