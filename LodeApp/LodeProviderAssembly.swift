import KernelCore
import KitLLM
import LodePluginRootView
import ProviderAgentLoop
import ProviderAgentRules
import ProviderChatSection
import ProviderCommand
import ProviderConversation
import ProviderConversationInput
import ProviderConversationInputBlock
import ProviderDeveloperMode
import ProviderExternalFile
import ProviderIdleTime
import ProviderLegacyData
import ProviderLifecycleHooks
import ProviderLLMContext
import ProviderLLMManager
import ProviderMessage
import ProviderMessageRendering
import ProviderMessageStreaming
import ProviderNetwork
import ProviderProject
import ProviderPromptSuggestion
import ProviderPromptSuggestionExecutor
import ProviderRailView
import ProviderRootView
import ProviderSkill
import ProviderStorage
import ProviderTheme
import ProviderToolManager
import ProviderWebServer
import SwiftUI

/// Lode 的 App 域装配：基线 Provider 之外的注册与启动后接线。
///
/// 基线（根视图 / 设置 / Logo / 主题 / 工具栏 / 入口栏 / 内容区 / 存储 /
/// 插件管理 / Toast / 磁盘缓存等）由 `KernelAssembler` 统一注册；这里只保留
/// 数据库工作区真正消费的差异部分，注册顺序沿用迁移前的依赖接线约定。
@MainActor
enum LodeProviderAssembly {

    /// IdleTime 插件的持久化目录名必须与插件自身 ID 一致。
    private static let idleTimePluginID = "com.coffic.lumi.plugin.idle-time"
    private static let toolManagerID = "com.coffic.lumi.plugin.tool-manager"
    static let apiKeyService = "com.coffic.lode.apikey"

    // MARK: - App Providers（插件 boot 之前）

    static func register(kernel: KernelCoreContainer, isolateAPIKeys: Bool) throws {
        // 必须在供应商插件启动前切换，测试进程也不能落到 Lode 的正式 Keychain。
        VendorAPIKeyTools.keychainService = isolateAPIKeys
            ? "\(apiKeyService).xctest.\(ProcessInfo.processInfo.processIdentifier)"
            : apiKeyService

        let storage = try kernel.requireProvider((any StorageProviding).self)

        try kernel.registerProvider((any ChatSectionProviding).self, DefaultChatSectionProviding())

        let conversations = DefaultConversationManager()
        try kernel.registerProvider((any ConversationManaging).self, conversations)

        let messages = DefaultMessageManager()
        try kernel.registerProvider((any MessageManaging).self, messages)

        // 上下文 Provider 是 AgentLoop 获取 LLM 消息的唯一入口。
        // 目前先注册透传实现，后续由上下文压缩插件替换为摘要实现；
        // 这样插件缺失时仍保持原有完整历史行为。
        try kernel.registerProvider(
            (any LLMContextProviding).self,
            PassthroughLLMContextProvider(messages: messages)
        )

        try kernel.registerProvider((any SuperLLMProvider).self, DefaultLLMProviding())

        // 流式输出 store：先于 AgentLoop 注册，供回合循环写入临时行。
        let streaming = DefaultMessageStreamingProviding()
        try kernel.registerProvider((any MessageStreamingProviding).self, streaming)

        // 生命周期钩子管理器：先于 AgentLoop 注册，回合循环在各关键节点触发钩子。
        let lifecycleHooks = DefaultLifecycleHooksProvider()
        try kernel.registerProvider((any LifecycleHooksProviding).self, lifecycleHooks)

        // LLM Provider 管理器：各供应商的注册表 + 选中持久化 + 路由发送。
        let providerManager = DefaultLLMManager()
        try kernel.registerProvider((any LLMManaging).self, providerManager)

        let toolManager = DefaultToolManagerProviding()
        toolManager.recordStore = ToolCallRecordStore(
            databaseRootURL: storage.pluginDataDirectory(for: Self.toolManagerID)
        )
        try kernel.registerProvider((any ToolManagerProviding).self, toolManager)

        let agentLoop = DefaultAgentLoopProvider(
            messages: messages,
            llmManager: providerManager,
            toolManager: toolManager,
            streaming: streaming,
            conversations: conversations
        )
        agentLoop.setLifecycleHooks(lifecycleHooks)
        try kernel.registerProvider((any AgentLoopProviding).self, agentLoop)

        // 输入插件通过自己的窄播观察器消费文本、光标和高度等高频状态。
        try kernel.registerProvider((any ConversationInputProviding).self, DefaultConversationInputProvider())
        // 跨插件递交的折叠内容块（如编辑器选区发送到对话）由输入插件消费。
        try kernel.registerProvider((any ConversationInputBlockProviding).self, DefaultConversationInputBlockProvider())
        try kernel.registerProvider((any MessageRenderingProviding).self, DefaultMessageRenderingProviding())
        try kernel.registerProvider((any ToolCallRenderingProviding).self, DefaultToolCallRenderingProviding())
        try kernel.registerProvider((any PromptSuggestionProviding).self, DefaultPromptSuggestionProvider())
        try kernel.registerProvider(
            (any PromptSuggestionExecuting).self,
            DefaultPromptSuggestionExecutor(kernel: kernel)
        )
        try kernel.registerProvider((any CommandProviding).self, DefaultCommandProviding())
        try kernel.registerProvider(
            (any IdleTimeProviding).self,
            IdleTimeService(
                store: IdleActivityStore(
                    directoryURL: storage.pluginDataDirectory(for: Self.idleTimePluginID)
                )
            )
        )
        try kernel.registerProvider((any LegacyDataProviding).self, DefaultLegacyDataProviding())
        try kernel.registerProvider((any WebServerProviding).self, DefaultWebServerProviding())
        try kernel.registerProvider((any ExternalFileOpening).self, DefaultExternalFileOpening())
        try kernel.registerProvider((any NetworkProviding).self, DefaultNetworkProviding())
        try kernel.registerProvider((any RailViewProviding).self, DefaultRailViewProviding())
        try kernel.registerProvider((any ProjectProviding).self, DefaultProjectProvider())
        // Skill / Agent Rule / 开发者模式必须在插件启动前注册，
        // 使各插件在 onBoot 中能解析到并注入贡献。
        try kernel.registerProvider((any SkillProviding).self, DefaultSkillProvider())
        try kernel.registerProvider((any AgentRuleProviding).self, DefaultAgentRuleProvider())
        try kernel.registerProvider((any DeveloperModeProviding).self, DefaultDeveloperModeProviding())

        // 基线主题 Provider 的默认存储目录与 Lode 历史路径不同：
        // 指回插件数据目录（<数据根>/ThemeManager/），重新载入用户已保存的主题选择。
        if let theme = kernel.resolveProvider((any ThemeProviding).self) as? DefaultThemeProviding {
            theme.setStorageDirectory(storage.pluginDataDirectory(for: "ThemeManager"))
        }
    }

    // MARK: - Post-start Wiring（共享接线之后）

    /// 共享接线（工具栏 / 入口栏 / 内容区）之外的 Workbench 视图挂载：
    /// Rail 侧栏与对话尾栏。贡献字段是 `@Published`，必须在装配期写入而非
    /// SwiftUI body 求值期，否则触发 "Publishing changes from within view updates"。
    static func wire(kernel: KernelCoreContainer) {
        guard let rootView = kernel.resolveProvider((any RootViewProviding).self) else { return }

        if let rail = kernel.resolveProvider((any RailViewProviding).self) {
            rootView.setRailView(rail.makeRailView())
            rootView.setRailViewVisible(rail.hasVisibleTabs)
            rootView.bindRailViewVisibility(to: rail)
            rootView.bindRailViewWidth(
                to: rail,
                onResize: { rail.saveCurrentWidth($0) }
            )
        }

        if let chat = kernel.resolveProvider((any ChatSectionProviding).self) {
            let trailingPane = RootTrailingPane(
                id: "com.coffic.lumi.workspace.chat",
                width: chat.chatSectionWidth,
                isVisible: chat.isVisible,
                content: AnyView(
                    chat.makeChatSectionView()
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("lode.chat.pane")
                )
            )
            trailingPane.bindVisibility(to: chat)
            trailingPane.bindWidth(
                to: chat,
                onResize: { chat.saveCurrentWidth($0) }
            )
            rootView.setTrailingPane(trailingPane)

            if let conversations = kernel.resolveProvider((any ConversationManaging).self) {
                chat.bindConversationSelection(conversations)
            }
        }
    }
}