import Foundation
import ProviderPromptSuggestion

/// Lode 聊天空态里的示例提示。
///
/// 点击后直接发送到当前会话（没有会话时自动新建）；连接、schema 与
/// 编辑器上下文由 Lode 既有的请求钩子注入，提示本身只描述意图。
@MainActor
enum LodeChatSuggestions {

    static func register(on provider: any PromptSuggestionProviding) {
        for suggestion in all {
            provider.register(suggestion)
        }
    }

    private static var all: [PromptSuggestion] {
        [
            PromptSuggestion(
                id: "com.coffic.lode.suggestion.schema-overview",
                title: String(localized: "Explore the schema"),
                prompt: "List the tables in the current database and summarize what each one stores.",
                order: 10,
                systemImage: "tablecells"
            ),
            PromptSuggestion(
                id: "com.coffic.lode.suggestion.draft-query",
                title: String(localized: "Draft a query"),
                prompt: "Draft a SQL query that returns the 10 most recent rows from the current table.",
                order: 20,
                systemImage: "wand.and.stars"
            ),
            PromptSuggestion(
                id: "com.coffic.lode.suggestion.explain-sql",
                title: String(localized: "Explain this SQL"),
                prompt: "Explain what the SQL in the current editor does, step by step.",
                order: 30,
                systemImage: "text.alignleft"
            ),
            PromptSuggestion(
                id: "com.coffic.lode.suggestion.optimize-sql",
                title: String(localized: "Optimize a query"),
                prompt: "Review the SQL in the current editor and suggest concrete performance improvements.",
                order: 40,
                systemImage: "gauge.with.needle"
            ),
        ]
    }
}