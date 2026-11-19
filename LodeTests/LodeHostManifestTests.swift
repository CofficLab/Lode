import KernelCore
import ProviderChatSection
import ProviderConversation
import ProviderExternalFile
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