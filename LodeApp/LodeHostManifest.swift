import DatabaseManagerPlugin
import KernelCore
import LumiFactory
import PluginAbout
import PluginCodeEditorHost
import PluginConversationInput
import PluginConversationList
import PluginConversationNew
import PluginConversationState
import PluginLLMProviderAiRouter
import PluginLLMProviderAliyun
import PluginLLMProviderAnthropic
import PluginLLMProviderDeepSeek
import PluginLLMProviderFeifeimiao
import PluginLLMProviderFlyMux
import PluginLLMProviderHappyCode
import PluginLLMProviderHyperAPI
import PluginLLMProviderKimiCode
import PluginLLMProviderLPgpt
import PluginLLMProviderMegaLLM
import PluginLLMProviderMiniMax
import PluginLLMProviderOpenAI
import PluginLLMProviderOpenCode
import PluginLLMProviderCommandCode
import PluginLLMProviderOpenRouter
import PluginLLMProviderStepFun
import PluginLLMProviderSublyx
import PluginLLMProviderTencent
import PluginLLMProviderXiaomi
import PluginLLMProviderXybbz
import PluginLLMProviderZhipu
import PluginLLMProviderMLX
import PluginLLMProviderSettings
import PluginMessageListStandard
import PluginMessageRenderer
import PluginMessageSender
import PluginModelSelector
import PluginSettingGeneral
import PluginSettingView
import LodePluginRootView
import ProviderExternalFile
import ProviderRootView
import SwiftUI

/// Lode 的宿主清单：与共享装配引擎（LumiFactory）之间的全部差异。
///
/// 装配流水线（基线 Provider → 迁移 → 启动 → 接线）、窗口壳、设置深链、
/// 外部文件打开排队全部由 `KernelAssembler` / `HostAppDelegate` 统一解释；
/// 这里只声明品牌身份、插件目录、存储/主题配置与三个钩子：
/// - `registerProviders`：基线未覆盖的 App 域 Provider（数据库工具链依赖的
///   对话 / LLM / 工具管理 / Rail / 外部文件等），并把主题持久化目录指回
///   插件数据目录（保住用户已有的主题选择）；
/// - `wireKernel`：共享接线未覆盖的 Rail / 对话尾栏视图挂载与对话绑定；
/// - `makeMainView`：标准根视图组装 + 首窗构建耗时测量（纯读取）。
@MainActor
enum LodeHostManifest {

    static func make(
        checkForUpdates: (@MainActor @Sendable () -> Void)? = nil
    ) -> HostManifest {
        HostManifest(
            identity: HostIdentity(
                appName: "Lode",
                loggerSubsystem: "com.coffic.lode",
                mainWindowID: "lode.main",
                settingsWindowID: "lode.settings",
                accessibilityPrefix: "lode",
                mainWindowDefaultSize: CGSize(width: 1100, height: 760),
                settingsWindowDefaultSize: CGSize(width: 960, height: 600)
            ),
            makePlugins: { makePlugins() },
            storage: HostStorageConfiguration(
                // 沿用历史插件 id：启用状态与旧目录数据继续可读。
                stateStorePluginID: "com.coffic.lumi.plugin.plugin-manager",
                dataRootDirectoryOverride: { uiTestDataRoot() },
                legacyDirectoryMigrations: [
                    "com.coffic.lumi.plugin.plugin-manager": ["PluginManager"],
                    "com.coffic.lumi.plugin.tool-manager": ["ToolManager"],
                ]
            ),
            theme: HostThemeConfiguration(storageDirectoryName: "ThemeManager"),
            legacyPluginIDAliases: [
                "com.coffic.lumi.plugin.plugin-manager": "com.coffic.lumi.plugin.plugin-manager",
                "com.coffic.lumi.plugin.caffeinate": "Caffeinate",
            ],
            // 根视图是 host provider：Workbench 布局（Rail + 尾栏 + 底部面板）
            // 由本地 PluginRootView 提供，不再经 RootViewPlugin 注册。
            makeRootViewProvider: { LumiRootViewProvider() },
            registerProviders: { kernel in
                try LodeProviderAssembly.register(
                    kernel: kernel,
                    isolateAPIKeys: uiTestDataRoot() != nil
                )
            },
            wireKernel: { kernel in
                LodeProviderAssembly.wire(kernel: kernel)
            },
            makeMainView: { kernel in
                var view = AnyView(EmptyView())
                LaunchPerformance.shared.measure(.firstWindow) {
                    view = kernel.resolveProvider((any RootViewProviding).self)?.makeRootView()
                        ?? AnyView(EmptyView())
                }
                return view
            },
            features: HostFeatures(
                openExternalPath: { kernel, url in
                    _ = kernel.resolveProvider((any ExternalFileOpening).self)?.open(url)
                },
                checkForUpdates: checkForUpdates,
                // AX 契约（与 GitOK 一致）：容器/内容级 id 会被 SwiftUI 传播
                // 遮蔽后代标识，关闭内容标识、改用 1×1 就绪标记 overlay。
                appliesWindowContentIdentifiers: false,
                usesReadyMarkerOverlays: true
            )
        )
    }

    // MARK: - Plugin Assembly

    /// 聊天能力由 LumiChat 同源插件提供；编辑器宿主与数据库插件是硬依赖，
    /// 强制 alwaysOn，不允许用户在插件管理里禁用（禁用后主窗口只剩空内容）。
    static func makePlugins() -> [any SuperPlugin] {
        // 测试隔离模式下不读真实保存的连接配置：宿主进程共享用户真实的
        // UserDefaults/Keychain，启动期同步读密码会触发钥匙串授权弹窗并挂起装配。
        let loadSavedConfigs = uiTestDataRoot() == nil
        return [
            SettingGeneralPlugin(
                configuration: SettingGeneralConfiguration(
                    pluginID: "com.coffic.lode.plugin.setting-general",
                    loggerSubsystem: "com.coffic.lode.plugin.setting-general",
                    applicationName: "Lode",
                    description: "Registers the General settings entry with app info, website and updates.",
                    openSettingsNotificationName: "lode.openSettings",
                    uninstallBranding: UninstallBranding(
                        applicationName: "Lode",
                        willUninstallNotificationName: "com.coffic.lode.uninstall.will-uninstall",
                        confirmationPhrase: "删除 Lode 数据",
                        applicationDataDisplayName: "Lode 数据",
                        applicationDisplayName: "Lode 应用",
                        whitelistDescriptionName: "Lode",
                        bundleIdentifierPrefix: "com.coffic.lode",
                        legacyBundleIdentifier: "com.coffic.Lode",
                        appGroupIdentifiers: [],
                        debugAppGroupIdentifiers: [],
                        legacyApplicationSupportDirectories: ["Lode"],
                        keychainServices: [
                            "com.coffic.lode.apikey",
                            "com.coffic.lumi.plugin.database-manager",
                        ],
                        debugKeychainServices: []
                    ),
                    showsUpdateChannelSection: true,
                    showsCLIInstallSection: false,
                    websiteURLString: "https://coffic.cn/lode",
                    privacyPolicyURLString: "https://coffic.cn/privacy",
                    termsOfServiceURLString: "https://coffic.cn/terms"
                )
            ),
            PluginSettingView(id: "com.coffic.lumi.plugin.setting-view"),
            MessageSenderPlugin(),
            ConversationStatePlugin(),
            MessageRendererPlugin(),
            AiRouterProviderPlugin(),
            AliyunProviderPlugin(),
            AnthropicProviderPlugin(),
            DeepSeekProviderPlugin(),
            FeifeimiaoProviderPlugin(),
            FlyMuxProviderPlugin(),
            HappyCodeProviderPlugin(),
            HyperAPIProviderPlugin(),
            KimiCodeProviderPlugin(),
            LPgptProviderPlugin(),
            MegaLLMProviderPlugin(),
            MiniMaxProviderPlugin(),
            OpenAIProviderPlugin(),
            OpenCodeProviderPlugin(),
            CommandCodeProviderPlugin(),
            OpenRouterProviderPlugin(),
            StepFunProviderPlugin(),
            SublyxProviderPlugin(),
            TencentProviderPlugin(),
            XiaomiProviderPlugin(),
            XybbzProviderPlugin(),
            ZhipuProviderPlugin(),
            LodeMLXProviderPlugin(),
            PluginMessageListStandardPlugin(),
            ModelSelectorPlugin(),
            ConversationInputPlugin(),
            ConversationListPlugin(),
            ConversationNewPlugin(),
            LLMProviderSettingsPlugin(),
            AboutPlugin(
                id: "com.coffic.lode.plugin.about",
                configuration: AboutConfiguration(
                    officialWebsiteURLString: "https://coffic.cn/lode",
                    privacyPolicyURLString: "https://coffic.cn/privacy",
                    termsOfServiceURLString: "https://coffic.cn/terms"
                )
            ),
            DedicatedAlwaysOnPlugin(CodeEditorHostPlugin()),
            DedicatedAlwaysOnPlugin(DatabaseManagerPlugin(loadSavedConfigs: loadSavedConfigs)),
        ]
    }

    // MARK: - UI Test Isolation

    private static func uiTestDataRoot() -> URL? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LODE_UI_TEST_DATA_ROOT"]
            .flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
            }
        #else
        return nil
        #endif
    }
}

/// 复用 MLX 供应商装配，但不把 Lumi 的历史模型目录复制进 Lode。
@MainActor
private final class LodeMLXProviderPlugin: SuperPlugin {
    private let wrapped = MLXProviderPlugin()

    var id: String { wrapped.id }
    var order: Int { wrapped.order }
    var dependencies: [String] { wrapped.dependencies }
    var metadata: PluginMetadata { wrapped.metadata }

    func onBoot(kernel: KernelCoreContainer) throws { try wrapped.onBoot(kernel: kernel) }
    func onShutdown(kernel: KernelCoreContainer) throws { try wrapped.onShutdown(kernel: kernel) }
}

/// 包装插件元数据为 `.alwaysOn`，其余生命周期行为原样透传。
@MainActor
private final class DedicatedAlwaysOnPlugin: SuperPlugin {
    private let wrapped: any SuperPlugin

    init(_ wrapped: any SuperPlugin) { self.wrapped = wrapped }

    var id: String { wrapped.id }
    var order: Int { wrapped.order }
    var dependencies: [String] { wrapped.dependencies }
    var metadata: PluginMetadata {
        PluginMetadata(
            id: wrapped.metadata.id,
            name: wrapped.metadata.name,
            description: wrapped.metadata.description,
            version: wrapped.metadata.version,
            category: wrapped.metadata.category,
            stage: wrapped.metadata.stage,
            policy: .alwaysOn,
            permissions: wrapped.metadata.permissions
        )
    }

    func onBoot(kernel: KernelCoreContainer) throws { try wrapped.onBoot(kernel: kernel) }
    func onReady(kernel: KernelCoreContainer) throws { try wrapped.onReady(kernel: kernel) }
    func onShutdown(kernel: KernelCoreContainer) throws { try wrapped.onShutdown(kernel: kernel) }
    func onEnable(kernel: KernelCoreContainer) async throws { try await wrapped.onEnable(kernel: kernel) }
    func onDisable(kernel: KernelCoreContainer) async throws { try await wrapped.onDisable(kernel: kernel) }
}