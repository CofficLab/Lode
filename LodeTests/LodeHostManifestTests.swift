import DatabaseManagerPlugin
import KernelCore
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

    func testSharedChatAssemblyProvidesInputModelSelectorAndSQLProposal() async throws {
        let kernel = try await makeKernel()

        let pluginIDs = [
            "com.coffic.lumi.plugin.message-sender",
            "com.coffic.lumi.plugin.conversation-state",
            "CoreMessageRenderer",
            "com.coffic.lumi.plugin.llm-provider.openai",
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

        let rootView = try XCTUnwrap(kernel.resolveProvider((any RootViewProviding).self))
        XCTAssertEqual(rootView.trailingPane?.id, "com.coffic.lumi.workspace.chat")
        XCTAssertNotNil(rootView.trailingPane?.content)

        let llmManager = try XCTUnwrap(kernel.resolveProvider((any LLMManaging).self))
        XCTAssertTrue(llmManager.allProviders().contains { $0.providerID == "openai" })

        let tools = try XCTUnwrap(kernel.resolveProvider((any ToolManagerProviding).self))
        XCTAssertNotNil(tools.tool(named: DatabaseProposeSQLV2Tool.toolName))

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

        try? await kernel.stopAsync()
    }
}