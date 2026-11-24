import KernelCore
import LumiLoggingKit
import os
import ProviderChatSection
import ProviderConversation
import ProviderMessage
import ProviderPromptSuggestion
import SwiftUI

/// 聊天空态插件：未选中会话、或当前会话尚无消息时接管聊天正文。
///
/// 与消息列表共用 `message-list` 互斥槽位：有消息时本插件退场，
/// 消息列表按原有路径渲染，因此空态不会与正文叠加。
@MainActor
public final class ChatEmptyStatePlugin: SuperPlugin, SuperLog {
    public static let pluginID = "com.coffic.lode.plugin.chat-empty-state"
    nonisolated static let logger = Logger(
        subsystem: "com.coffic.lode.plugin.chat-empty-state",
        category: "ChatEmptyState"
    )

    public let id = ChatEmptyStatePlugin.pluginID
    public let order = 81
    public let metadata = PluginMetadata(
        id: ChatEmptyStatePlugin.pluginID,
        name: "Chat Empty State",
        description: "无会话或消息时的聊天欢迎页",
        category: .chat,
        stage: .stable,
        policy: .alwaysOn
    )

    private var chat: (any ChatSectionProviding)?
    private var conversations: (any ConversationManaging)?
    private var messages: (any MessageManaging)?
    private var suggestions: (any PromptSuggestionProviding)?
    private var executor: (any PromptSuggestionExecuting)?
    private var selectedObserver: (any SelectedConversationObserverHandle)?
    private var messageObserver: (any MessageChangeObserverHandle)?
    private var suggestionObserver: (any PromptSuggestionProvidingObserverHandle)?
    private var chatObserver: (any ChatSectionProvidingObserverHandle)?
    private var isRegistered = false

    public init() {}

    public func onBoot(kernel: KernelCoreContainer) throws {
        guard let chat = kernel.resolveProvider((any ChatSectionProviding).self) else {
            Self.logger.error("\(Self.t)Failed to resolve ChatSectionProviding from kernel")
            return
        }

        let conversations = kernel.resolveProvider((any ConversationManaging).self)
        let messages = kernel.resolveProvider((any MessageManaging).self)
        let suggestions = kernel.resolveProvider((any PromptSuggestionProviding).self)
        let executor = kernel.resolveProvider((any PromptSuggestionExecuting).self)

        self.chat = chat
        self.conversations = conversations
        self.messages = messages
        self.suggestions = suggestions
        self.executor = executor

        chat.addItems([
            ChatSectionItem(
                id: id,
                order: order,
                exclusiveGroup: "message-list",
                fillsRemainingHeight: true,
                // 空态与底部输入区属于同一段画面，由宿主统一绘制分隔线。
                showsTrailingDivider: false,
                isActive: { @MainActor [weak self] in
                    self?.shouldRenderEmptyState ?? false
                },
                content: { @MainActor [weak self] in
                    self?.makeContentView() ?? AnyView(EmptyView())
                }
            )
        ])
        isRegistered = true

        selectedObserver = conversations?.addSelectedConversationObserver { @MainActor [weak self] _ in
            self?.chat?.refreshItems()
        }
        messageObserver = messages?.addMessageChangeObserver { @MainActor [weak self] change in
            guard let self,
                  let changedID = Self.conversationID(of: change),
                  changedID == self.conversations?.selectedConversationID else { return }
            self.chat?.refreshItems()
        }
        suggestionObserver = suggestions?.addObserver { @MainActor [weak self] _ in
            self?.chat?.refreshItems()
        }
        chatObserver = chat.addObserver { @MainActor [weak self] event in
            guard case .activeContextChanged = event else { return }
            self?.chat?.refreshItems()
        }
    }

    public func onShutdown(kernel: KernelCoreContainer) throws {
        selectedObserver?.cancel()
        selectedObserver = nil
        messageObserver?.cancel()
        messageObserver = nil
        suggestionObserver?.cancel()
        suggestionObserver = nil
        chatObserver?.cancel()
        chatObserver = nil
        if isRegistered {
            chat?.removeItem(id: id)
            isRegistered = false
        }
        executor = nil
        suggestions = nil
        messages = nil
        conversations = nil
        chat = nil
    }

    /// 未选中会话，或选中会话还没有任何可展示消息时展示欢迎页。
    private var shouldRenderEmptyState: Bool {
        guard let selectedID = conversations?.selectedConversationID else { return true }
        guard let messages else { return true }
        return messages
            .messagePage(
                for: selectedID,
                limit: 1,
                beforeMessageID: nil,
                includesToolMessages: false
            )
            .isEmpty
    }

    private func makeContentView() -> AnyView {
        let visible = ChatEmptyStateSuggestions.visible(
            from: suggestions?.allSuggestions ?? [],
            contextID: chat?.activeContext?.id
        )
        let executor = executor
        return AnyView(
            ChatEmptyStateView(suggestions: visible) { suggestion in
                guard let executor else { return }
                Task { @MainActor in
                    await executor.execute(suggestion, pickProjectFolder: nil)
                }
            }
        )
    }

    private static func conversationID(of change: MessageChange) -> UUID? {
        switch change {
        case let .inserted(_, conversationID),
             let .persisted(_, conversationID),
             let .updated(conversationID),
             let .deleted(_, conversationID),
             let .cleared(conversationID):
            return conversationID
        }
    }
}