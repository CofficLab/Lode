import AppKit
import Combine
import ProviderEditor
import LumiUI
import SwiftUI

/// 主面板：Query 编辑器 + 结果区。
///
/// 表/键浏览已迁移到 RailView（`DatabaseSidebarView`），
/// 本视图仅负责数据展示和查询操作。
/// 连接管理迁到了工具栏右上角 `DatabaseToolbarButton` 的 popover。
public struct MainView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    /// 由 ``DatabaseManagerPluginSupport`` 注入，与 ``DatabaseToolbarButton`` 共享同一个实例，
    /// 这样在工具栏 popover 中选中/断开连接会立即反映到主面板。
    @ObservedObject var viewModel: DatabaseViewModel

    /// 由本视图的「去添加」按钮触发；popover 中的 Add Connection 共享同一个表单。
    @State private var showAddConfigSheet = false
    @Environment(\.colorScheme) private var colorScheme

    public init(viewModel: DatabaseViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isConnected {
                connectedContent
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAddConfigSheet) {
            ConnectionFormView(viewModel: viewModel, isPresented: $showAddConfigSheet)
        }
        .sheet(item: $viewModel.configPendingEdit) { config in
            ConnectionFormView(viewModel: viewModel, isPresented: Binding(
                get: { viewModel.configPendingEdit != nil },
                set: { if !$0 { viewModel.configPendingEdit = nil } }
            ), editing: config)
        }
        .sheet(isPresented: $viewModel.showHistory) {
            QueryHistoryView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.objectDefinition) { definition in
            ObjectDefinitionSheet(definition: definition) {
                viewModel.objectDefinition = nil
            }
        }
        .confirmationDialog(
            pluginLocalization.string("Discard changes?"),
            isPresented: Binding(
                get: { viewModel.pendingCloseTabID != nil },
                set: { if !$0 { viewModel.cancelClosePendingTab() } }
            ),
            titleVisibility: .visible
        ) {
            Button(pluginLocalization.string("Close Without Saving"), role: .destructive) {
                viewModel.confirmClosePendingTab()
            }
            Button(pluginLocalization.string("Cancel"), role: .cancel) {
                viewModel.cancelClosePendingTab()
            }
        } message: {
            Text(pluginLocalization.string("This tab has unsaved changes. Closing it will discard them."))
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private var connectedContent: some View {
        if viewModel.openTableObject != nil {
            // 从侧边栏打开了表/视图 → 统一分页浏览
            TableDataView(viewModel: viewModel)
        } else {
            VStack(spacing: 0) {
                QueryTabStrip(viewModel: viewModel)
                AppDivider()
                queryEditor
                if !viewModel.activeParameterNames.isEmpty {
                    QueryParameterPanel(viewModel: viewModel)
                    AppDivider()
                }
                toolbar
                AppDivider()
                QueryResultSectionView(viewModel: viewModel)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var queryEditor: some View {
        EmbeddedCodeEditorView(
            text: $viewModel.queryText,
            options: EditorEmbeddedEditorOptions(languageID: "sql", completionProvider: viewModel.sqlCompletionProvider),
            provider: viewModel.embeddedEditorProvider,
            cursorLocation: $viewModel.editorCursorLocation,
            selectionRange: $viewModel.editorSelectionRange
        )
            .frame(minHeight: 100, maxHeight: 200)
            .border(theme.appSubtleBorder)
    }

    private var toolbar: some View {
        let statementCount = SQLStatementParser.split(viewModel.queryText).count
        return AppToolbarContainer(height: 48) {
            HStack {
                Spacer()
                if viewModel.isConnected {
                    AppButton(pluginLocalization.string("Disconnect"), systemImage: "bolt.horizontal.circle", style: .secondary, size: .small, action: { Task { await viewModel.disconnect() } })
                }
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                    QueryElapsedLabel()
                    AppButton(pluginLocalization.string("Stop"), systemImage: "stop.fill", style: .secondary, size: .small, action: { Task { await viewModel.cancelRunningQuery() } })
                        .keyboardShortcut(.return, modifiers: .command)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    AppButton(pluginLocalization.string("Run"), systemImage: "play.fill", style: .primary, size: .small, action: { Task { await viewModel.executeStatementAtCursor() } })
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(pluginLocalization.string("Run statement at cursor"))
                }
                if statementCount > 1 {
                    batchPolicyPicker
                    AppButton(
                        "\(pluginLocalization.string("Run All")) (\(statementCount))",
                        systemImage: "play.rectangle.fill",
                        style: .secondary,
                        size: .small,
                        action: { Task { await viewModel.executeAllStatements() } }
                    )
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(viewModel.isLoading)
                }
                AppButton(
                    pluginLocalization.string("Format"),
                    systemImage: "text.alignleft",
                    style: .ghost,
                    size: .small,
                    action: { viewModel.formatDocumentOrSelection() }
                )
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help(pluginLocalization.string("Format SQL (selection or document)"))
                AppButton(
                    pluginLocalization.string("History"),
                    systemImage: "clock.arrow.circlepath",
                    style: .ghost,
                    size: .small,
                    action: { viewModel.showHistory = true }
                )
                .keyboardShortcut("y", modifiers: .command)
            }
        }
    }

    // MARK: - Batch policy

    /// ⌘⇧↩ 批量执行策略选择：逐句继续 / 包裹事务失败回滚。
    private var batchPolicyPicker: some View {
        Menu {
            Picker(pluginLocalization.string("Batch policy"), selection: $viewModel.batchPolicy) {
                Text(pluginLocalization.string("Continue on error"))
                    .tag(BatchExecutionPolicy.continueOnError)
                Text(pluginLocalization.string("Wrap in transaction"))
                    .tag(BatchExecutionPolicy.wrapInTransaction)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.batchPolicy == .wrapInTransaction ? "lock.rectangle" : "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                Text(pluginLocalization.string("Batch policy"))
                    .font(.appMicro)
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isLoading)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        MainEmptyStateView(viewModel: viewModel, onAddConnection: { showAddConfigSheet = true })
    }
}

/// 运行计时：出现即开始计时，随 isLoading 结束从视图树移除而停止。
private struct QueryElapsedLabel: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @State private var elapsed: TimeInterval = 0
    private let start = Date()
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(format: "%.1fs", elapsed))
            .font(.monospaced(.caption)())
            .foregroundStyle(theme.textSecondary)
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(start)
            }
    }
}


// MARK: - Preview
