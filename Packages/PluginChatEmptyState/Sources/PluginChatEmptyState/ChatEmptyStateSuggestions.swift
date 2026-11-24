import Foundation
import ProviderChatSection
import ProviderPromptSuggestion

/// 空态可展示的示例提示。
///
/// 宿主没有项目维度，`onlyWithProject` 一律隐藏；其余按 `scope` 与当前
/// 聊天上下文匹配，避免工作台切换后仍显示过期的入口。
@MainActor
enum ChatEmptyStateSuggestions {
    static func visible(
        from all: [PromptSuggestion],
        contextID: String?
    ) -> [PromptSuggestion] {
        all.filter { suggestion in
            guard suggestion.visibility != .onlyWithProject else { return false }

            switch suggestion.scope {
            case .global:
                return true
            case .launcher:
                return isLauncher(contextID)
            case let .context(expectedID):
                return expectedID == contextID
            case let .launcherAndContext(expectedID):
                return isLauncher(contextID) || expectedID == contextID
            }
        }
    }

    private static func isLauncher(_ contextID: String?) -> Bool {
        contextID == nil || contextID == ChatContext.defaultChat.id
    }
}