import SwiftUI
import LumiUI

/// 查询编辑器顶部的多标签条。
///
/// 沿用内容区工具条风格（Material 背景 + 语义色）：每个标签显示标题、脏标记
/// （未保存改动）或运行进度，选中态高亮；右侧提供新建与「重开最近关闭」。
/// 双击或右键菜单可重命名；关闭脏标签由 ``DatabaseViewModel/pendingCloseTabID``
/// 触发确认弹窗（在 ``MainView`` 挂载）。
struct QueryTabStrip: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    @ObservedObject var viewModel: DatabaseViewModel
    @ObservedObject private var workspace: QueryWorkspaceStore

    @State private var hoveredTabID: UUID?
    @State private var renameRequest: RenameRequest?

    private struct RenameRequest: Identifiable {
        let id: UUID
        var title: String
    }

    init(viewModel: DatabaseViewModel) {
        self.viewModel = viewModel
        self.workspace = viewModel.workspace
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if !workspace.recentlyClosed.isEmpty {
                    AppIconButton(
                        systemImage: "arrow.uturn.backward",
                        label: pluginLocalization.string("Reopen Closed"),
                        size: .compact,
                        action: { viewModel.reopenLastClosedTab() }
                    )
                    .help(pluginLocalization.string("Reopen last closed tab"))
                }
                AppIconButton(
                    systemImage: "plus",
                    label: pluginLocalization.string("New Tab"),
                    size: .compact,
                    action: { viewModel.newQueryTab() }
                )
                .help(pluginLocalization.string("New query tab"))
                .keyboardShortcut("t", modifiers: .command)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(Material.regularMaterial)
        .sheet(item: $renameRequest) { request in
            renameSheet(request)
        }
    }

    // MARK: - Tab button

    private func tabButton(_ tab: QueryTab) -> some View {
        let isSelected = workspace.activeTabID == tab.id
        let isRunning = viewModel.runningTabID == tab.id
        let showClose = isSelected || hoveredTabID == tab.id
        return HStack(spacing: 5) {
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 8, height: 8)
            } else if tab.isDirty {
                Circle()
                    .fill(theme.warning)
                    .frame(width: 6, height: 6)
            } else if tab.isFileBacked {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 8, height: 8)
            }
            Text(tab.title)
                .font(.appMicro)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .frame(maxWidth: 140)
            if showClose {
                Button {
                    viewModel.closeQueryTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pluginLocalization.string("Close tab"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? theme.primary.opacity(0.15) : Color.clear)
        .clipShape(.rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.isDirty
            ? pluginLocalization.string("Unsaved changes")
            : (isRunning ? pluginLocalization.string("Running") : ""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { viewModel.selectQueryTab(id: tab.id) }
        .accessibilityAction(named: pluginLocalization.string("Close")) {
            viewModel.closeQueryTab(id: tab.id)
        }
        .accessibilityAction(named: pluginLocalization.string("Rename…")) {
            renameRequest = RenameRequest(id: tab.id, title: tab.title)
        }
        .onHover { hoveredTabID = $0 ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID) }
        .onTapGesture { viewModel.selectQueryTab(id: tab.id) }
        .onTapGesture(count: 2) { renameRequest = RenameRequest(id: tab.id, title: tab.title) }
        .contextMenu {
            Button(pluginLocalization.string("Rename…")) {
                renameRequest = RenameRequest(id: tab.id, title: tab.title)
            }
            Button(pluginLocalization.string("Close")) {
                viewModel.closeQueryTab(id: tab.id)
            }
        }
    }

    // MARK: - Rename sheet

    private func renameSheet(_ request: RenameRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pluginLocalization.string("Rename Tab"))
                .font(.appTitle)
                .foregroundStyle(theme.textPrimary)
            GlassTextField(
                title: pluginLocalization.string("Title"),
                text: Binding(
                    get: { renameRequest?.title ?? request.title },
                    set: { renameRequest?.title = $0 }
                ),
                placeholder: pluginLocalization.string("Query")
            )
            HStack {
                Spacer()
                AppButton(pluginLocalization.string("Cancel"), style: .secondary, size: .small) {
                    renameRequest = nil
                }
                AppButton(pluginLocalization.string("Save"), style: .primary, size: .small) {
                    if let current = renameRequest {
                        viewModel.renameQueryTab(id: current.id, title: current.title)
                    }
                    renameRequest = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .appSurface()
    }
}