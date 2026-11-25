import SwiftUI
import LumiUI

/// Redis 命名空间键树侧边栏：按分隔符聚合的折叠树 + 搜索过滤 + SCAN 分页「加载更多」。
///
/// 数据来自 ``DatabaseViewModel/redisKeyTree``（由已加载键聚合）。点击叶子键打开
/// 类型化详情面板；分支节点展示子树键数。搜索按完整键名子串过滤后重建树。
struct RedisKeyTreeView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel
    var onToggleMode: () -> Void

    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            DatabaseSidebarHeaderBar(
                title: pluginLocalization.string("Keys"),
                systemImage: "key",
                onLoad: { Task { await viewModel.loadRedisKeys() } },
                onToggleMode: onToggleMode,
                toggleMode: viewModel.sidebarMode,
                menuActions: [
                    DatabaseSidebarMenuAction(
                        title: "Back to Connections",
                        systemImage: "rectangle.portrait.on.rectangle.portrait",
                        action: onToggleMode
                    ),
                ]
            )

            searchBar

            if displayTree.isEmpty {
                SidebarEmptyView(
                    systemImage: "key",
                    title: pluginLocalization.string("No keys"),
                    description: pluginLocalization.string("Click Reload to refresh the key list.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        OutlineGroup(displayTree, id: \.id, children: \.outlineChildren) { node in
                            if let fullKey = node.fullKey {
                                leafRow(node, fullKey: fullKey)
                            } else {
                                branchRow(node)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(pluginLocalization.string("Filter keys"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.appCaption)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.appSubtleBorder, in: .rect(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// 搜索时按完整键名过滤后重建树；否则直接用 VM 聚合好的树。
    private var displayTree: [RedisKeyTreeNode] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return viewModel.redisKeyTree }
        let filtered = viewModel.redisKeys.filter { $0.lowercased().contains(needle) }
        return RedisKeyTreeBuilder.build(keys: filtered, separator: viewModel.redisKeySeparator)
    }

    // MARK: - Rows

    private func leafRow(_ node: RedisKeyTreeNode, fullKey: String) -> some View {
        let isSelected = viewModel.selectedRedisKey?.key == fullKey
        return AppSidebarRow(
            title: node.name,
            systemImage: "key",
            leadingColor: nil,
            isSelected: isSelected
        ) {
            Task { await viewModel.openRedisKey(fullKey) }
        }
        .help(fullKey)
        .contextMenu {
            Button {
                Task { await viewModel.openRedisKey(fullKey) }
            } label: {
                Label(pluginLocalization.string("Open"), systemImage: "arrow.right.circle")
            }
            Button(role: .destructive) {
                Task { await viewModel.applyRedisEdit(.delete(key: fullKey)) }
            } label: {
                Label(pluginLocalization.string("Delete Key"), systemImage: "trash")
            }
        }
    }

    private func branchRow(_ node: RedisKeyTreeNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.appMicroEmphasized)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(node.keyCount)")
                .font(.appMicro)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if viewModel.isLoadingRedisKeys || viewModel.redisHasMoreKeys || !viewModel.redisKeys.isEmpty {
            AppDivider()
            HStack(spacing: 8) {
                Text(String(format: pluginLocalization.string("%d keys"), viewModel.redisKeys.count))
                    .font(.appMicro)
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 4)
                if viewModel.isLoadingRedisKeys {
                    ProgressView().scaleEffect(0.5)
                } else if viewModel.redisHasMoreKeys {
                    AppButton(pluginLocalization.string("Load More Keys"), systemImage: "arrow.down.circle", style: .ghost, size: .small) {
                        Task { await viewModel.loadMoreRedisKeys() }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
    }
}