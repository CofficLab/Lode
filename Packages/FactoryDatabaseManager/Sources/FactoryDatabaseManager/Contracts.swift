import Foundation
import KernelCore
import KitLLM
import ProviderActivityBar
import ProviderAgentLoop
import ProviderAgentRules
import ProviderChatSection
import ProviderCommand
import ProviderContentView
import ProviderConversation
import ProviderConversationInput
import ProviderConversationInputBlock
import ProviderDeveloperMode
import ProviderDocsView
import ProviderExternalFile
import ProviderIdleTime
import ProviderLegacyData
import ProviderLifecycleHooks
import ProviderLLMManager
import ProviderLogo
import ProviderMenuBar
import ProviderMessage
import ProviderMessageRendering
import ProviderMessageSender
import ProviderMessageStreaming
import ProviderNetwork
import ProviderPluginControl
import ProviderPluginManaging
import ProviderProject
import ProviderPromptSuggestion
import ProviderRailView
import ProviderRootView
import ProviderSettingView
import ProviderSkill
import ProviderStorage
import ProviderToast
import ProviderToolbar
import ProviderToolManager
import ProviderWebServer
import SwiftUI

/// 产出各种 Provider 实现的工厂协议。
@MainActor
public protocol ProviderFactory {
    func makeStorageProvider() -> any StorageProviding

    func makeContentViewProvider() -> any ContentViewProviding

    func makeChatSectionProvider() -> any ChatSectionProviding

    func makeConversationProvider() -> any ConversationManaging
    func makeMessageProvider() -> any MessageManaging
    func makeAgentLoopProvider(
        messages: any MessageManaging,
        llmManager: any LLMManaging,
        toolManager: any ToolManagerProviding,
        streaming: any MessageStreamingProviding,
        conversations: any ConversationManaging
    ) -> any AgentLoopProviding
    func makeLLMProvider() -> any SuperLLMProvider
    func makeMessageSenderProvider(
        conversations: any ConversationManaging,
        messages: any MessageManaging,
        agentLoop: any AgentLoopProviding
    ) -> any MessageSendingProviding

    func makeLLMProviderManagerProvider() -> any LLMManaging

    func makeDocsViewProvider() -> any DocsViewProviding

    func makeMenuBarProvider() -> any MenuBarProviding

    func makeLogoProvider() -> any LogoProviding

    func makeProjectProvider() -> any ProjectProviding

    func makeToastProvider() -> any ToastProviding

    func makeNetworkProvider() -> any NetworkProviding

    func makeToolbarProvider() -> any ToolbarProviding

    func makeRootViewProvider() -> any RootViewProviding

    func makeActivityBarProvider() -> any ActivityBarProviding

    func makeRailViewProvider() -> any RailViewProviding

    func makeSettingViewProvider() -> any SettingViewProviding

    func makeToolManagerProvider() -> any ToolManagerProviding

    func makeConversationInputProvider() -> any ConversationInputProviding
    func makeConversationInputBlockProvider() -> any ConversationInputBlockProviding
    func makeMessageStreamingProvider() -> any MessageStreamingProviding
    func makeMessageRenderingProvider() -> any MessageRenderingProviding
    func makeToolCallRenderingProvider() -> any ToolCallRenderingProviding
    func makePromptSuggestionProvider() -> any PromptSuggestionProviding
    func makeCommandProvider() -> any CommandProviding
    func makeIdleTimeProvider(storage: any StorageProviding) -> any IdleTimeProviding
    func makeLegacyDataProvider() -> any LegacyDataProviding
    func makePluginControlProvider(kernel: KernelCoreContainer) -> any PluginControlling

    func makePluginManagingProvider(
        kernel: KernelCoreContainer,
        controlling: any PluginControlling
    ) -> any PluginManaging

    func makeWebServerProvider() -> any WebServerProviding
    func makeExternalFileProvider() -> any ExternalFileOpening

    func makeLifecycleHooksProvider() -> any LifecycleHooksProviding

    func makeSkillProvider() -> any SkillProviding

    func makeAgentRuleProvider() -> any AgentRuleProviding

    func makeDeveloperModeProvider() -> any DeveloperModeProviding

    func registerProviders(into kernel: KernelCoreContainer) throws
}

public extension ProviderFactory {
    func makeExternalFileProvider() -> any ExternalFileOpening {
        DefaultExternalFileOpening()
    }
}

/// 产出各种插件的工厂协议。
@MainActor
public protocol PluginFactory {
    func makePlugins() -> [any SuperPlugin]

    func didRegisterProviders(in kernel: KernelCoreContainer)
}

public extension PluginFactory {
    func didRegisterProviders(in kernel: KernelCoreContainer) {}
}

/// 产出视图的工厂协议。
@MainActor
public protocol ViewFactory {
    func makeMainView(kernel: KernelCoreContainer) throws -> AnyView

    func makeSettingsView(kernel: KernelCoreContainer) throws -> AnyView
}
