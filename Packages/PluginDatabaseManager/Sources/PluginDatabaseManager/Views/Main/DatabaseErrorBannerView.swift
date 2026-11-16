import SwiftUI
import LumiUI

/// 分类错误条：本地化类别标题 + 原始细节 + 恢复动作按钮。
///
/// 恢复动作由 ``DatabaseErrorCategory/suggestedRecovery`` 决定：
/// 网络/超时/断连 → 重试；认证/库不存在/权限 → 编辑连接；其余仅展示。
struct DatabaseErrorBannerView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    let classified: ClassifiedDatabaseError

    var body: some View {
        let title = pluginLocalization.string(classified.category.localizationKey)
        let message = classified.detail.isEmpty ? title : "\(title): \(classified.detail)"
        switch classified.recovery {
        case .retry:
            AppErrorBanner(
                message: LocalizedStringKey(message),
                retryTitle: LocalizedStringKey(pluginLocalization.string("Retry")),
                onRetry: { Task { await viewModel.retryLastAction() } }
            )
        case .editConnection:
            AppErrorBanner(
                message: LocalizedStringKey(message),
                retryTitle: LocalizedStringKey(pluginLocalization.string("Edit Connection")),
                onRetry: { viewModel.requestEditConnection() }
            )
        case .none:
            AppErrorBanner(message: LocalizedStringKey(message))
        }
    }
}