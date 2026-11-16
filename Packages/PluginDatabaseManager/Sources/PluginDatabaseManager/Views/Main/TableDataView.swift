import LumiUI
import SwiftUI

/// 统一的表数据浏览视图：顶部标题栏 + 分页条 + 结果区。
///
/// 当 ``DatabaseViewModel/openTableObject`` 非空时由 ``MainView`` 显示，
/// 适用于 SQLite/MySQL/PostgreSQL（Redis 走键浏览路径）。
/// 分页通过 `LIMIT/OFFSET`，行数通过后台 `COUNT(*)` 异步填充。
struct TableDataView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel

    private let pageSizes: [Int] = [50, 100, 200, 500, 1000]

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            if viewModel.gridFindVisible {
                gridFindBar
                AppDivider()
            }
            if viewModel.showFilterPanel {
                TableFilterPanel(viewModel: viewModel)
                AppDivider()
            }
            QueryResultSectionView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if viewModel.changeManager?.hasChanges == true {
                changesBar
                AppDivider()
            }
            paginationBar
        }
        .sheet(isPresented: $viewModel.showChangePreview) {
            ChangePreviewSheet(
                statements: viewModel.pendingChangeSQL,
                isPresented: $viewModel.showChangePreview,
                onSave: { Task { await viewModel.saveChanges() } }
            )
        }
        .sheet(isPresented: $viewModel.showConflictSheet) {
            ConflictResolutionSheet(
                conflicts: viewModel.pendingConflicts,
                isPresented: $viewModel.showConflictSheet,
                onOverwrite: { Task { await viewModel.overwriteConflictsAndSave() } },
                onDiscard: { Task { await viewModel.discardConflictedRowsAndSave() } },
                onCancel: { viewModel.cancelConflictResolution() }
            )
        }
        .focusedSceneValue(\.gridEditActions, GridEditActions(
            copyPageCSV: { copyToPasteboard(viewModel.gridPageText(.csv)) },
            copyPageMarkdown: { copyToPasteboard(viewModel.gridPageText(.markdown)) },
            pasteRows: { pasteRowsFromPasteboard() },
            canPaste: viewModel.changeManager?.isEditable == true && viewModel.queryResult != nil,
            findInGrid: { viewModel.showGridFind() }
        ))
        .onChange(of: viewModel.gridFindText) { _, _ in
            if viewModel.gridFindVisible, viewModel.gridFindScope == .currentPage {
                viewModel.refreshCurrentPageFindMatches()
            }
        }
    }

    // MARK: - Grid find bar

    /// 查找条：查找词 + 范围（当前页/全量）+ 匹配导航 + 关闭。
    private var gridFindBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            TextField(pluginLocalization.string("Find in Grid"), text: $viewModel.gridFindText)
                .textFieldStyle(.plain)
                .font(.appBody)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 220)
                .background(theme.surface)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.appSubtleBorder, lineWidth: 1))
                .onSubmit { Task { await viewModel.runGridFind() } }

            Picker(pluginLocalization.string("Find Scope"), selection: gridFindScopeBinding) {
                Text(pluginLocalization.string("Current Page")).tag(GridFindScope.currentPage)
                Text(pluginLocalization.string("All Rows")).tag(GridFindScope.allRows)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            if viewModel.gridFindScope == .currentPage {
                Text(findMatchCountText)
                    .font(.appMicro)
                    .foregroundStyle(theme.textSecondary)
                    .frame(minWidth: 60, alignment: .leading)
                AppIconButton(systemImage: "chevron.up", label: pluginLocalization.string("Previous Match"), size: .compact) {
                    viewModel.prevGridFindMatch()
                }
                .disabled(viewModel.gridFindMatches.isEmpty)
                AppIconButton(systemImage: "chevron.down", label: pluginLocalization.string("Next Match"), size: .compact) {
                    viewModel.nextGridFindMatch()
                }
                .disabled(viewModel.gridFindMatches.isEmpty)
            } else if viewModel.isLoading {
                ProgressView().scaleEffect(0.6)
            }

            Spacer()
            AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Close Find"), size: .compact) {
                viewModel.closeGridFind()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .appSurface(style: .toolbar, cornerRadius: 0)
    }

    private var findMatchCountText: String {
        let total = viewModel.gridFindMatches.count
        if total == 0 {
            return viewModel.gridFindText.isEmpty ? "" : pluginLocalization.string("No matches")
        }
        return "\(viewModel.gridFindMatchIndex + 1) / \(total)"
    }

    private var gridFindScopeBinding: Binding<GridFindScope> {
        Binding(
            get: { viewModel.gridFindScope },
            set: { newValue in
                viewModel.gridFindScope = newValue
                Task { await viewModel.runGridFind() }
            }
        )
    }

    // MARK: - Copy & Paste

    private func pasteRowsFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        viewModel.gridPasteRows(from: text)
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Changes bar

    private var changesBar: some View {
        let cm = viewModel.changeManager
        return HStack(spacing: 8) {
            Image(systemName: "pencil.line")
                .foregroundStyle(theme.warning)
            Text(changeSummary(cm))
                .font(.appMicroEmphasized)
                .foregroundStyle(theme.textPrimary)

            AppIconButton(systemImage: "arrow.uturn.backward", label: pluginLocalization.string("Undo"), size: .compact) {
                viewModel.undoChange()
            }
            .disabled(cm?.canUndo != true)

            AppIconButton(systemImage: "arrow.uturn.forward", label: pluginLocalization.string("Redo"), size: .compact) {
                viewModel.redoChange()
            }
            .disabled(cm?.canRedo != true)

            Spacer()
            AppButton(pluginLocalization.string("Preview SQL"), systemImage: "doc.text.magnifyingglass", style: .ghost, size: .small) {
                viewModel.showChangePreview = true
            }
            AppButton(pluginLocalization.string("Discard"), systemImage: "trash", style: .secondary, size: .small) {
                viewModel.discardChanges()
            }
            AppButton(pluginLocalization.string("Save"), systemImage: "checkmark.circle.fill", style: .primary, size: .small) {
                Task { await viewModel.saveChanges() }
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(theme.warning.opacity(0.08))
    }

    /// 变更条摘要：按类型列出 edit/insert/delete 计数。
    private func changeSummary(_ cm: TableChangeManager?) -> String {
        guard let cm else { return "" }
        var parts: [String] = []
        if cm.changedCellCount > 0 {
            parts.append("\(cm.changedCellCount) \(pluginLocalization.string("edits"))")
        }
        if cm.pendingInsertCount > 0 {
            parts.append("\(cm.pendingInsertCount) \(pluginLocalization.string("new"))")
        }
        if cm.pendingDeleteCount > 0 {
            parts.append("\(cm.pendingDeleteCount) \(pluginLocalization.string("deletes"))")
        }
        return parts.isEmpty
            ? pluginLocalization.string("No changes")
            : parts.joined(separator: " · ") + " " + pluginLocalization.string("unsaved")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appBodyEmphasized)
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let count = viewModel.tableRowCount {
                    Text("\(viewModel.tableRowCountIsApproximate ? "~" : "")\(count.formatted()) \(pluginLocalization.string("rows"))")
                        .font(.appCaption)
                        .foregroundColor(theme.textSecondary)
                        .help(viewModel.tableRowCountIsApproximate
                              ? pluginLocalization.string("Approximate row count")
                              : pluginLocalization.string("Exact row count"))
                } else if viewModel.isLoading {
                    Text(pluginLocalization.string("Loading…"))
                        .font(.appCaption)
                        .foregroundColor(theme.textSecondary)
                }
            }
            Spacer()
            if viewModel.isLoading {
                ProgressView().scaleEffect(0.6)
            }
            if viewModel.changeManager?.isEditable == true {
                AppButton(
                    pluginLocalization.string("Add Row"),
                    systemImage: "plus",
                    style: .secondary,
                    size: .small,
                    action: { viewModel.addRow() }
                )
                .keyboardShortcut("n", modifiers: [.command, .shift])
                AppButton(
                    pluginLocalization.string("Paste Rows"),
                    systemImage: "doc.on.clipboard",
                    style: .secondary,
                    size: .small,
                    action: { pasteRowsFromPasteboard() }
                )
                .help(pluginLocalization.string("Paste CSV or JSON rows as new rows"))
            }
            AppButton(
                pluginLocalization.string("Refresh"),
                systemImage: "arrow.clockwise",
                style: .secondary,
                size: .small,
                action: { Task { await viewModel.loadTablePage() } }
            )
            AppButton(
                pluginLocalization.string("Filter"),
                systemImage: "line.3.horizontal.decrease.circle",
                style: viewModel.tableFilter.isActive ? .primary : .secondary,
                size: .small,
                action: { viewModel.showFilterPanel.toggle() }
            )
            AppButton(
                pluginLocalization.string("Structure"),
                systemImage: "list.bullet.rectangle",
                style: .secondary,
                size: .small,
                action: { viewModel.inspectorVisible = true }
            )
            AppButton(
                pluginLocalization.string("SQL"),
                systemImage: "curlybraces",
                style: .ghost,
                size: .small,
                action: { viewModel.switchToQueryEditor() }
            )
            Menu {
                Toggle(isOn: $viewModel.useNullSymbol) {
                    Text(pluginLocalization.string("Show NULL as ⟨NULL⟩"))
                }
                if viewModel.tableRowCountIsApproximate {
                    Divider()
                    Button(pluginLocalization.string("Exact Count")) {
                        Task { await viewModel.refreshExactRowCount() }
                    }
                }
                if viewModel.gridHasRowKey {
                    Divider()
                    Toggle(isOn: keysetBinding) {
                        Text(pluginLocalization.string("Keyset Pagination"))
                    }
                    .help(pluginLocalization.string("Fast deep paging by primary key"))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(pluginLocalization.string("Display Options"))
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .appSurface(style: .toolbar, cornerRadius: 0)
    }

    private var title: String {
        let conn = viewModel.selectedConfig?.name ?? ""
        let table = viewModel.openTableObject?.name ?? ""
        return table.isEmpty ? conn : "\(conn) / \(table)"
    }

    // MARK: - Pagination bar

    private var paginationBar: some View {
        let total = viewModel.tableRowCount ?? 0
        let pageCount = max(1, (total + viewModel.tablePageSize - 1) / viewModel.tablePageSize)
        let currentPage = min(viewModel.tablePage + 1, pageCount)

        return HStack(spacing: 8) {
            AppIconButton(systemImage: "chevron.left", label: pluginLocalization.string("Prev"), size: .compact) {
                Task { await viewModel.prevPage() }
            }
            .disabled(viewModel.tablePage == 0)

            Text(pluginLocalization.string("Page") + " \(currentPage) / \(pageCount.formatted())")
                .font(.appMicro)
                .foregroundStyle(.secondary)

            AppIconButton(systemImage: "chevron.right", label: pluginLocalization.string("Next"), size: .compact) {
                Task { await viewModel.nextPage() }
            }
            .disabled(currentPage >= pageCount)

            Spacer()

            Text(pluginLocalization.string("Rows") + ": \(rowRangeText(currentPage: viewModel.tablePage))")
                .font(.appMicro)
                .foregroundStyle(.secondary)

            Picker(pluginLocalization.string("Page Size"), selection: pageSizeBinding) {
                ForEach(pageSizes, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 90)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .appSurface(style: .toolbar, cornerRadius: 0)
    }

    private var pageSizeBinding: Binding<Int> {
        Binding(
            get: { viewModel.tablePageSize },
            set: { newSize in Task { await viewModel.setPageSize(newSize) } }
        )
    }

    private var keysetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.useKeysetPagination },
            set: { enabled in Task { await viewModel.setUseKeysetPagination(enabled) } }
        )
    }

    /// 当前页展示的行区间文本，如 "1–100"。
    private func rowRangeText(currentPage: Int) -> String {
        let pageSize = viewModel.tablePageSize
        let start = currentPage * pageSize + 1
        var end = start + pageSize - 1
        if let total = viewModel.tableRowCount { end = min(end, total) }
        if let result = viewModel.queryResult, result.rows.count < pageSize {
            end = start + result.rows.count - 1
        }
        return "\(start.formatted())–\(max(start, end).formatted())"
    }
}

#if DEBUG
#Preview("Table Data") {
    TableDataView(viewModel: DatabaseViewModel())
        .frame(width: 720, height: 460)
}
#endif
