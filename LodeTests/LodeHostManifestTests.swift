import DatabaseManagerPlugin
import KernelCore
import KitLLM
import PluginAbout
import PluginSettingGeneral
import ProviderChatSection
import ProviderConversation
import ProviderExternalFile
import ProviderLLMManager
import ProviderRailView
import ProviderRootView
import ProviderToolbar
import ProviderToolManager
import XCTest
@testable import Lode

/// LodeHostManifest 集成测试：共享装配引擎解释清单后的真实内核基线。
@MainActor
final class LodeHostManifestTests: LodeKernelTestCase {

    /// 专用装配强制启用编辑器与数据库插件，sqlite 外部打开经宿主钩子可达。
    func testDedicatedAssemblyEnablesEditorAndDatabasePlugins() async throws {
        let kernel = try await makeKernel()
        XCTAssertTrue(kernel.isPluginEnabled(id: "com.coffic.lumi.plugin.editor-host"))
        XCTAssertTrue(kernel.isPluginEnabled(id: "com.coffic.lumi.plugin.database-manager"))

        let opener = try XCTUnwrap(kernel.resolveProvider((any ExternalFileOpening).self))
        let sqliteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lode-manifest-test-\(UUID().uuidString).sqlite")
        XCTAssertTrue(opener.open(sqliteURL))
        try? FileManager.default.removeItem(at: sqliteURL)
        try? await kernel.stopAsync()
    }

    func testAPIKeyServiceIsLodeSpecificAndIsolated() async throws {
        let kernel = try await makeKernel()

        XCTAssertEqual(LodeProviderAssembly.apiKeyService, "com.coffic.lode.apikey")
        XCTAssertTrue(
            VendorAPIKeyTools.keychainService.hasPrefix("\(LodeProviderAssembly.apiKeyService).xctest.")
        )
        XCTAssertFalse(VendorAPIKeyTools.keychainService.contains("lumi"))

        try? await kernel.stopAsync()
    }

    func testMLXAssemblySkipsLegacyModelImport() throws {
        let plugin = try XCTUnwrap(
            LodeHostManifest.makePlugins().first {
                $0.id == "com.coffic.lumi.plugin.llm-provider.mlx"
            }
        )
        XCTAssertFalse(plugin is any PluginDataMigrating)
    }

    func testSharedChatAssemblyProvidesInputModelSelectorAndSQLProposal() async throws {
        let kernel = try await makeKernel()

        let pluginIDs = [
            "com.coffic.lumi.plugin.message-sender",
            "com.coffic.lumi.plugin.conversation-state",
            "CoreMessageRenderer",
            "com.coffic.lumi.plugin.llm-provider.airouter",
            "com.coffic.lumi.plugin.llm-provider.aliyun",
            "com.coffic.lumi.plugin.llm-provider.anthropic",
            "com.coffic.lumi.plugin.llm-provider.deepseek",
            "com.coffic.lumi.plugin.llm-provider.feifeimiao",
            "com.coffic.lumi.plugin.llm-provider.flymux",
            "com.coffic.lumi.plugin.llm-provider.happycode",
            "com.coffic.lumi.plugin.llm-provider.hyperapi",
            "com.coffic.lumi.plugin.llm-provider.kimicode",
            "com.coffic.lumi.plugin.llm-provider.lpgpt",
            "com.coffic.lumi.plugin.llm-provider.megallm",
            "com.coffic.lumi.plugin.llm-provider.minimax",
            "com.coffic.lumi.plugin.llm-provider.openai",
            "com.coffic.lumi.plugin.llm-provider.opencode",
            "com.coffic.lumi.plugin.llm-provider.commandcode",
            "com.coffic.lumi.plugin.llm-provider.openrouter",
            "com.coffic.lumi.plugin.llm-provider.stepfun",
            "com.coffic.lumi.plugin.llm-provider.sublyx",
            "com.coffic.lumi.plugin.llm-provider.tencent",
            "com.coffic.lumi.plugin.llm-provider.xiaomi",
            "com.coffic.lumi.plugin.llm-provider.xybbz",
            "com.coffic.lumi.plugin.llm-provider.zhipu",
            "com.coffic.lumi.plugin.llm-provider.mlx",
            "com.coffic.lumi.plugin.message-list.standard",
            "com.coffic.lumi.plugin.model-selector",
            "com.coffic.lumi.plugin.conversation-input",
            "com.coffic.lumi.plugin.llm-provider-settings",
        ]
        for id in pluginIDs {
            XCTAssertTrue(kernel.isPluginEnabled(id: id), "Missing chat plugin: \(id)")
        }

        let chat = try XCTUnwrap(
            kernel.resolveProvider((any ChatSectionProviding).self) as? DefaultChatSectionProviding
        )
        XCTAssertTrue(chat.items.contains { $0.id == "com.coffic.lumi.plugin.conversation-input" })
        XCTAssertTrue(chat.barItems.contains { $0.id == "com.coffic.lumi.plugin.model-selector.action-bar-button" })

        // 聊天窗头部 / 工具栏 / 操作栏的内容全部来自插件；这些条目缺失时
        // ChatSection 会渲染出一段空的 chrome 条。
        XCTAssertTrue(chat.isContextActive)
        let barItemIDs = Set(chat.barItems.map(\.id))
        for id in [
            "com.coffic.lumi.plugin.conversation-title.header",
            "com.coffic.lumi.plugin.conversation-token-usage.header",
            "com.coffic.lumi.plugin.conversation-elapsed-time.header",
            "com.coffic.lumi.plugin.conversation-agent-turn-count.toolbar-button",
            "com.coffic.lumi.plugin.conversation-speed.toolbar-button",
            "com.coffic.lumi.plugin.conversation-cache-hit-rate.toolbar-button",
            "com.coffic.lumi.plugin.conversation-mode.toolbar-button",
            "com.coffic.lumi.plugin.verbosity.toolbar-button",
            "com.coffic.lumi.plugin.conversation-language.toolbar-button",
            "com.coffic.lumi.plugin.conversation-export.toolbar",
            "com.coffic.lumi.plugin.tool-activity.toolbar",
            "com.coffic.lumi.plugin.llm-context.context-toolbar-button",
            "com.coffic.lumi.plugin.chat-file-attachment.button",
            "com.coffic.lumi.plugin.chat-screenshot.button",
        ] {
            XCTAssertTrue(barItemIDs.contains(id), "Missing chat bar item: \(id)")
        }

        let rootView = try XCTUnwrap(kernel.resolveProvider((any RootViewProviding).self))
        XCTAssertEqual(rootView.trailingPane?.id, "com.coffic.lumi.workspace.chat")
        XCTAssertNotNil(rootView.trailingPane?.content)

        // 未选中会话时，正文由空态插件接管 message-list 槽位。
        XCTAssertTrue(kernel.isPluginEnabled(id: "com.coffic.lode.plugin.chat-empty-state"))
        let emptyStateItem = chat.items.first { $0.id == "com.coffic.lode.plugin.chat-empty-state" }
        XCTAssertEqual(emptyStateItem?.exclusiveGroup, "message-list")
        XCTAssertTrue(emptyStateItem?.isActive() == true)

        let llmManager = try XCTUnwrap(kernel.resolveProvider((any LLMManaging).self))
        XCTAssertEqual(llmManager.providerCount, 33)
        XCTAssertEqual(llmManager.allProviders().filter { $0.providerInfo.isLocal }.count, 7)

        let tools = try XCTUnwrap(kernel.resolveProvider((any ToolManagerProviding).self))
        XCTAssertNotNil(tools.tool(named: DatabaseProposeSQLV2Tool.toolName))

        try? await kernel.stopAsync()
    }

    func testConversationToolbarPluginsFollowChatSelection() async throws {
        let kernel = try await makeKernel()
        let conversations = try XCTUnwrap(kernel.resolveProvider((any ConversationManaging).self))
        let chat = try XCTUnwrap(kernel.resolveProvider((any ChatSectionProviding).self))
        let toolbar = try XCTUnwrap(kernel.resolveProvider((any ToolbarProviding).self))
        let newChatItemID = "com.coffic.lumi.plugin.conversation-new.new-chat"
        let listItemID = "com.coffic.lumi.plugin.conversation-list.conversation-list"

        XCTAssertTrue(kernel.isPluginEnabled(id: "com.coffic.lumi.plugin.conversation-new"))
        XCTAssertTrue(kernel.isPluginEnabled(id: "com.coffic.lumi.plugin.conversation-list"))
        XCTAssertTrue(chat.isVisible)
        XCTAssertTrue(toolbar.visibleToolbarItems.contains { $0.id == listItemID })
        XCTAssertFalse(toolbar.toolbarItems.contains { $0.id == newChatItemID })

        _ = try conversations.createConversation(
            title: "Toolbar test",
            projectPath: nil,
            providerID: nil,
            modelName: nil
        )
        XCTAssertTrue(toolbar.visibleToolbarItems.contains { $0.id == newChatItemID })
        XCTAssertEqual(
            toolbar.visibleToolbarItems.first { $0.id == newChatItemID }?.placement,
            .trailing
        )
        XCTAssertEqual(
            toolbar.visibleToolbarItems.first { $0.id == listItemID }?.placement,
            .trailing
        )

        conversations.deselectConversation()
        XCTAssertFalse(toolbar.toolbarItems.contains { $0.id == newChatItemID })
        XCTAssertTrue(toolbar.visibleToolbarItems.contains { $0.id == listItemID })

        try? await kernel.stopAsync()
    }

    /// App 域 Provider 钩子与启动后接线：基线外能力就位，共享设置按钮接管工具栏。
    func testManifestRegistersAppProvidersAndWiring() async throws {
        let kernel = try await makeKernel()

        XCTAssertNotNil(kernel.resolveProvider((any ChatSectionProviding).self))
        XCTAssertNotNil(kernel.resolveProvider((any ConversationManaging).self))
        XCTAssertNotNil(kernel.resolveProvider((any ToolManagerProviding).self))
        XCTAssertNotNil(kernel.resolveProvider((any RailViewProviding).self))
        XCTAssertNotNil(kernel.resolveProvider((any RootViewProviding).self))

        // 共享工具栏设置按钮（取代旧 SettingsToolbarPlugin，id 沿用 "settings"）。
        let toolbar = try XCTUnwrap(kernel.resolveProvider((any ToolbarProviding).self))
        XCTAssertTrue(toolbar.toolbarItems.contains { $0.id == "settings" })
        XCTAssertTrue(kernel.isPluginEnabled(id: "com.coffic.lumi.plugin.setting-view"))

        try? await kernel.stopAsync()
    }

    /// 设置入口的品牌接线：共享包必须拿到 Lode 身份，且不重复注册 ⌘,。
    func testSettingsEntriesUseLodeBrandConfiguration() throws {
        let plugins = LodeHostManifest.makePlugins()

        let general = try XCTUnwrap(plugins.compactMap { $0 as? SettingGeneralPlugin }.first)
        XCTAssertEqual(general.id, "com.coffic.lode.plugin.setting-general")
        XCTAssertEqual(general.configuration.applicationName, "Lode")
        XCTAssertEqual(
            general.configuration.uninstallBranding.bundleIdentifierPrefix,
            "com.coffic.lode"
        )
        XCTAssertEqual(general.configuration.openSettingsNotificationName, "lumi.openSettings")
        XCTAssertFalse(general.configuration.registersOpenSettingsCommand)
        XCTAssertFalse(general.configuration.showsUpdateChannelSection)
        XCTAssertFalse(general.configuration.showsDiagnosticsSection)

        let about = try XCTUnwrap(plugins.compactMap { $0 as? AboutPlugin }.first)
        XCTAssertEqual(about.id, "com.coffic.lode.plugin.about")
        XCTAssertEqual(about.configuration.officialWebsiteURLString, "https://coffic.cn/lode")
    }
}