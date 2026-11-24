import KernelCore
import ProviderChatSection
import ProviderConversation
import ProviderMessage
import ProviderPromptSuggestion
import Testing
@testable import PluginChatEmptyState

@Suite("ChatEmptyStatePlugin")
@MainActor
struct ChatEmptyStatePluginTests {

    private struct Context {
        let kernel: KernelCoreContainer
        let chat: DefaultChatSectionProviding
        let conversations: DefaultConversationManager
        let messages: DefaultMessageManager
        let plugin: ChatEmptyStatePlugin
    }

    private func makeContext() throws -> Context {
        let kernel = KernelCoreContainer()
        let chat = DefaultChatSectionProviding()
        try kernel.registerProvider((any ChatSectionProviding).self, chat)
        let conversations = DefaultConversationManager()
        try kernel.registerProvider((any ConversationManaging).self, conversations)
        let messages = DefaultMessageManager()
        try kernel.registerProvider((any MessageManaging).self, messages)
        let plugin = ChatEmptyStatePlugin()
        try plugin.onBoot(kernel: kernel)
        return Context(
            kernel: kernel,
            chat: chat,
            conversations: conversations,
            messages: messages,
            plugin: plugin
        )
    }

    @Test("未选中会话时以 message-list 槽位接管正文")
    func showsWithoutSelectedConversation() throws {
        let ctx = try makeContext()
        let item = try #require(ctx.chat.items.first { $0.id == ChatEmptyStatePlugin.pluginID })

        #expect(item.exclusiveGroup == "message-list")
        #expect(item.fillsRemainingHeight)
        #expect(item.showsTrailingDivider == false)
        #expect(item.isActive())

        try ctx.plugin.onShutdown(kernel: ctx.kernel)
        #expect(ctx.chat.items.contains { $0.id == ChatEmptyStatePlugin.pluginID } == false)
    }

    @Test("空会话保持空态，写入消息后让位给消息列表")
    func hidesWhenConversationHasMessages() throws {
        let ctx = try makeContext()
        let item = try #require(ctx.chat.items.first { $0.id == ChatEmptyStatePlugin.pluginID })

        let conversationID = try ctx.conversations.createConversation(
            title: "Empty conversation",
            projectPath: nil,
            providerID: nil,
            modelName: nil
        )
        #expect(ctx.conversations.selectedConversationID == conversationID)
        #expect(item.isActive())

        ctx.messages.insertMessage(
            Message(conversationID: conversationID, role: .user, content: "Hello"),
            to: conversationID
        )
        #expect(item.isActive() == false)

        ctx.messages.clearMessages(in: conversationID)
        #expect(item.isActive())
    }

    @Test("示例提示按可见性与聊天上下文过滤")
    func filtersSuggestions() {
        let all = [
            PromptSuggestion(id: "global", title: "Global"),
            PromptSuggestion(id: "project", title: "Project", visibility: .onlyWithProject),
            PromptSuggestion(id: "launcher", title: "Launcher", scope: .launcher),
            PromptSuggestion(id: "ctx-a", title: "Context A", scope: .context("a")),
            PromptSuggestion(id: "launcher-a", title: "Launcher A", scope: .launcherAndContext("a")),
        ]

        #expect(
            ChatEmptyStateSuggestions.visible(from: all, contextID: ChatContext.defaultChat.id).map(\.id)
                == ["global", "launcher", "launcher-a"]
        )
        #expect(
            ChatEmptyStateSuggestions.visible(from: all, contextID: nil).map(\.id)
                == ["global", "launcher", "launcher-a"]
        )
        #expect(
            ChatEmptyStateSuggestions.visible(from: all, contextID: "a").map(\.id)
                == ["global", "ctx-a", "launcher-a"]
        )
        #expect(
            ChatEmptyStateSuggestions.visible(from: all, contextID: "b").map(\.id)
                == ["global"]
        )
    }
}