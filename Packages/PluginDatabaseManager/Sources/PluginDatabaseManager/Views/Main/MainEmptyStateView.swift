import SwiftUI

/// ``MainView`` 的空状态视图。
///
/// 仅展示 ``MainEmptyStateHeaderView``（文案 + Add Connection 按钮）与连接错误提示；
/// 已保存的连接统一在侧边栏连接列表中浏览，主面板不再重复列出。
///
/// 与父视图的耦合通过两个入口参数降到最低：
/// - `viewModel`：用于读取连接错误展示态；
/// - `onAddConnection`：Add Connection 按钮的回调，由父视图决定是否弹出 sheet。
struct MainEmptyStateView: View {
    // MARK: - Properties

    /// 父视图注入的视图模型，用于读取状态与触发连接。
    @ObservedObject var viewModel: DatabaseViewModel

    /// 点击「Add Connection」按钮时触发的回调。
    let onAddConnection: () -> Void

    // MARK: - Initialization

    init(viewModel: DatabaseViewModel, onAddConnection: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onAddConnection = onAddConnection
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 20) {
            if let classified = viewModel.classifiedError {
                DatabaseErrorBannerView(viewModel: viewModel, classified: classified)
                    .frame(maxWidth: 480)
            }
            MainEmptyStateHeaderView(onAddConnection: onAddConnection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - 预览

#if DEBUG
#Preview("Empty - No Saved") {
    MainEmptyStateView(viewModel: DatabaseViewModel(), onAddConnection: {})
        .frame(width: 600, height: 400)
}
#endif