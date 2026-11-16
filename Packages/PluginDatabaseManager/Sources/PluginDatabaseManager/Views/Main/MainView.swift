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
        .focusedSceneValue(\.sqlFileActions, SQLFileActions(
            open: { viewModel.presentOpenSQLPanel() },
            save: { viewModel.saveActiveSQLFile() },
            saveAs: { viewModel.presentSaveSQLPanel() },
            canOpen: viewModel.isConnected,
            canSave: viewModel.isConnected && viewModel.openTableObject == nil
        ))
    }

    // MARK: - Connected

    @ViewBuilder
    private var connectedContent: some View {
        VStack(spacing: 0) {
            startupSQLNoticeBanner
            if viewModel.openTableObject != nil {
                // 从侧边栏打开了表/视图 → 统一分页浏览
                TableDataView(viewModel: viewModel)
            } else if viewModel.selectedRedisKey != nil {
                // 从键树打开了 Redis 键 → 类型化查看/编辑面板
                RedisKeyDetailView(viewModel: viewModel)
            } else {
                VStack(spacing: 0) {
                    QueryTabStrip(viewModel: viewModel)
                    AppDivider()
                    sqlFileConflictBanner
                    largeDocumentNotice
                    queryEditor
                    sqlDiagnosticsStrip
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 连接级 startup SQL 失败提示：连接已成功，仅会话引导脚本未跑通，故用 warning 语义色
    /// 自绘可关闭横幅（AppErrorBanner 无关闭按钮，且其 error 语义会误导为连接失败）。
    @ViewBuilder
    private var startupSQLNoticeBanner: some View {
        if let notice = viewModel.startupSQLNotice {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.warning)
                Text(notice)
                    .font(.appCaption)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                AppIconButton(
                    systemImage: "xmark",
                    label: pluginLocalization.string("Dismiss"),
                    size: .compact,
                    action: { viewModel.dismissStartupSQLNotice() }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.warning.opacity(0.1))
            AppDivider()
        }
    }

    private var queryEditor: some View {
        EmbeddedCodeEditorView(
            text: $viewModel.queryText,
            options: EditorEmbeddedEditorOptions(
                languageID: "sql",
                completionProvider: viewModel.sqlCompletionProvider,
                foldRanges: { SQLFoldRangeCalculator.foldRanges(in: $0).map(\.range) },
                diagnostics: { DatabaseViewModel.embeddedSQLDiagnostics($0) }
            ),
            provider: viewModel.embeddedEditorProvider,
            cursorLocation: $viewModel.editorCursorLocation,
            selectionRange: $viewModel.editorSelectionRange
        )
            .frame(minHeight: 100, maxHeight: 200)
            .border(theme.appSubtleBorder)
    }

    /// 结构化诊断条：列出编辑器文本的括号/引号/注释失配与形近/不可见字符，点击跳转到对应范围。
    @ViewBuilder
    private var sqlDiagnosticsStrip: some View {
        if !viewModel.sqlDiagnostics.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pluginLocalization.string("Problems"))
                        .font(.appMicroEmphasized)
                        .foregroundStyle(theme.textTertiary)
                    ForEach(Array(viewModel.sqlDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        diagnosticRow(diagnostic)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .frame(maxHeight: 76)
            .background(theme.surface)
        }
    }

    private func diagnosticRow(_ diagnostic: SQLStructuralDiagnostic) -> some View {
        Button {
            viewModel.jumpToSQLDiagnostic(diagnostic)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(diagnostic.severity == .error ? theme.error : theme.warning)
                Text(diagnosticMessage(diagnostic))
                    .font(.appMicro)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(diagnosticLocation(diagnostic))
                    .font(.appMicro)
                    .foregroundStyle(theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pluginLocalization.string("Jump to this problem"))
    }

    private func diagnosticMessage(_ diagnostic: SQLStructuralDiagnostic) -> String {
        switch diagnostic.kind {
        case .unmatchedOpeningBracket:
            return pluginLocalization.string("This opening bracket has no matching close.")
        case .unexpectedClosingBracket:
            return pluginLocalization.string("This closing bracket has no matching open.")
        case .unterminatedString:
            return pluginLocalization.string("This string literal is not closed.")
        case .unterminatedComment:
            return pluginLocalization.string("This block comment is not closed.")
        case .confusableCharacter(let ascii):
            return String(format: pluginLocalization.string("This character looks like '%@' but is not ASCII. Retype it."), ascii)
        case .invisibleCharacter:
            return pluginLocalization.string("Invisible character (zero-width or non-breaking space). Remove it.")
        }
    }

    /// 诊断范围的行/列标签（均 1 起），按 UTF-16 偏移在原文中换算。
    private func diagnosticLocation(_ diagnostic: SQLStructuralDiagnostic) -> String {
        let ns = viewModel.queryText as NSString
        let location = min(diagnostic.range.location, ns.length)
        let lines = ns.substring(to: location).components(separatedBy: "\n")
        let column = (lines.last ?? "").utf16.count + 1
        return String(format: pluginLocalization.string("Ln %d, Col %d"), lines.count, column)
    }

    /// SQL 文件外部变更横幅：Reload（采用磁盘版本）/ Save As（本地改动另存新文件）/ Keep Editing。
    /// AppErrorBanner 仅支持单按钮，故沿用 largeDocumentNotice 的语义色 HStack 自持双按钮。
    @ViewBuilder
    private var sqlFileConflictBanner: some View {
        if let conflict = viewModel.sqlFileConflict {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
                Text(bannerMessage(for: conflict))
                    .font(.appCaption)
                    .foregroundColor(theme.textSecondary)
                Spacer(minLength: 8)
                if conflict.change == .modified {
                    AppButton(pluginLocalization.string("Reload"), style: .secondary, size: .small) {
                        viewModel.reloadActiveSQLFile()
                    }
                    .help(pluginLocalization.string("Discard local edits and load the disk version"))
                }
                AppButton(pluginLocalization.string("Save As…"), style: .primary, size: .small) {
                    viewModel.presentSaveSQLPanel()
                }
                .help(pluginLocalization.string("Save local edits to a new file"))
                AppIconButton(
                    systemImage: "xmark",
                    label: pluginLocalization.string("Keep Editing"),
                    size: .compact,
                    action: { viewModel.dismissSQLFileConflict() }
                )
                .help(pluginLocalization.string("Keep editing and acknowledge the disk version"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.warning.opacity(0.12))
        }
    }

    private func bannerMessage(for conflict: SQLFileConflict) -> String {
        switch conflict.change {
        case .missing:
            return pluginLocalization.string("This file was moved or deleted. Save As to keep your edits in a new file.")
        case .modified:
            return conflict.isDirty
                ? pluginLocalization.string("This file was changed on disk. Reload to discard your edits, or Save As to keep them in a new file.")
                : pluginLocalization.string("This file was changed on disk. Reload to load the latest version.")
        case .unchanged:
            return ""
        }
    }

    /// 超大文档降级提示：达到阈值时高亮/折叠/解析已关闭，仅保留纯文本编辑。
    @ViewBuilder
    private var largeDocumentNotice: some View {
        if EditorDocumentGuard.isLargeDocument(viewModel.queryText) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
                Text(pluginLocalization.string("Large document: syntax highlighting, folding and parsing are disabled to keep editing responsive."))
                    .font(.appCaption)
                    .foregroundColor(theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.warning.opacity(0.12))
        }
    }

    private var toolbar: some View {
        let statementCount = SQLStatementParser.split(viewModel.queryText).count
        return AppToolbarContainer(height: 48) {
            HStack {
                AppIconButton(
                    systemImage: "folder",
                    label: pluginLocalization.string("Open SQL File…"),
                    size: .compact,
                    action: { viewModel.presentOpenSQLPanel() }
                )
                .help(pluginLocalization.string("Open SQL file"))
                AppIconButton(
                    systemImage: "square.and.arrow.down",
                    label: pluginLocalization.string("Save"),
                    size: .compact,
                    action: { viewModel.saveActiveSQLFile() }
                )
                .help(pluginLocalization.string("Save SQL file"))
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
                if viewModel.isConnected, viewModel.selectedConfig?.type != .redis {
                    AppButton(
                        pluginLocalization.string("Explain"),
                        systemImage: "list.bullet.indent",
                        style: .ghost,
                        size: .small,
                        action: { Task { await viewModel.explainCurrentQuery() } }
                    )
                    .disabled(viewModel.isLoading)
                    .help(pluginLocalization.string("Explain the current query"))
                }
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
