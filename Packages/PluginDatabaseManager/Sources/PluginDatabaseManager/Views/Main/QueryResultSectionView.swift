import SwiftUI
import LumiUI

/// ``MainView`` 的查询/数据结果展示区。
///
/// 三态展示：
/// 1. `viewModel.classifiedError` 非空 → 分类错误条（含恢复动作）；
/// 2. `viewModel.queryResult` 非空 → ``QueryResultView`` 渲染表格；
/// 3. 否则 → ``AppEmptyState`` 占位。
///
/// 当存在多语句执行结果（``DatabaseViewModel/multiExecutions`` 非空）时，
/// 顶部额外显示一条 tab 栏，每条语句一个 tab（成功 ✓ / 失败 ✗ + 耗时），
/// 点击切换当前显示的结果；选中结果仍通过 `viewModel.queryResult` 下发给
/// ``QueryResultView``，保持向后兼容。
struct QueryResultSectionView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    // MARK: - Properties

    @ObservedObject var viewModel: DatabaseViewModel

    /// 外键选择器请求（insertId 非空表示为新增行选值）。
    private struct FKPickerRequest: Identifiable {
        let id = UUID()
        let column: String
        let rowValues: [DatabaseValue]
        let columns: [String]
        let insertId: UUID?
    }

    @State private var fkPicker: FKPickerRequest?
    @State private var valueViewer: ValueViewerRequest?

    // MARK: - Initialization

    init(viewModel: DatabaseViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Body

    @ViewBuilder
    var body: some View {
        if !viewModel.multiExecutions.isEmpty {
            VStack(spacing: 0) {
                if viewModel.lastBatchRolledBack {
                    batchRolledBackBanner
                }
                multiExecutionTabs
                Divider()
                selectedResultContent
            }
        } else {
            singleResultContent
        }
    }

    // MARK: - Batch rolled back notice

    private var batchRolledBackBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.error)
            Text(pluginLocalization.string("Rolled back"))
                .font(.appBodyEmphasized)
                .foregroundStyle(theme.textPrimary)
            Text(pluginLocalization.string("All changes in this batch were rolled back."))
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.error.opacity(0.1))
    }

    // MARK: - Single result (no multi-exec)

    @ViewBuilder
    private var singleResultContent: some View {
        if let classified = viewModel.classifiedError {
            errorBanner(for: classified)
                .padding(12)
        } else if let result = viewModel.queryResult {
            VStack(spacing: 0) {
                QueryResultView(
                    result: result,
                    sortColumn: viewModel.tableOrderBy?.column,
                    sortAscending: viewModel.tableOrderBy?.ascending ?? true,
                    onToggleSort: { column in Task { await viewModel.toggleSort(column: column) } },
                    changeManager: viewModel.changeManager,
                    onStageChange: { column, rowValues, columns, newValue in
                        viewModel.stageCellChange(column: column, newValue: newValue, rowValues: rowValues, columns: columns)
                    },
                    onStageInsertChange: { insertId, column, value in
                        viewModel.stageInsertCell(insertId: insertId, column: column, value: value)
                    },
                    onToggleRowDeletion: { rowValues, columns in
                        viewModel.toggleRowDeletion(rowValues: rowValues, columns: columns)
                    },
                    onRemoveInsert: { insertId in
                        viewModel.removePendingInsert(insertId)
                    },
                    nullText: viewModel.useNullSymbol ? "⟨NULL⟩" : "NULL",
                    onStageDefault: { column, rowValues, columns in
                        Task { await viewModel.stageCellDefault(column: column, rowValues: rowValues, columns: columns) }
                    },
                    onClearInsertColumn: { insertId, column in
                        viewModel.clearPendingInsertColumn(insertId: insertId, column: column)
                    },
                    onChooseReference: { column, rowValues, columns in
                        fkPicker = FKPickerRequest(column: column, rowValues: rowValues, columns: columns, insertId: nil)
                    },
                    onJumpToReference: { column, rowValues, columns in
                        Task { await viewModel.jumpToReference(column: column, rowValues: rowValues, columns: columns) }
                    },
                    onChooseInsertReference: { insertId, column in
                        fkPicker = FKPickerRequest(column: column, rowValues: [], columns: [], insertId: insertId)
                    },
                    onCopyRowAs: { kind, row, columns in
                        copyToPasteboard(viewModel.gridCopyText(rowKind: kind, row: row, columns: columns))
                    },
                    onCopyInList: { column in
                        copyToPasteboard(viewModel.gridInListText(column: column))
                    },
                    onCopyPageAs: { kind in
                        copyToPasteboard(viewModel.gridPageText(kind))
                    },
                    canCopyUpdate: viewModel.gridHasRowKey,
                    onViewValue: { column, value in
                        valueViewer = ValueViewerRequest(column: column, value: value)
                    },
                    columnWidthOverrides: viewModel.gridColumnWidths,
                    displayColumnOrder: viewModel.gridColumnOrder.isEmpty ? nil : viewModel.gridColumnOrder,
                    onResizeColumn: { column, width in
                        viewModel.setGridColumnWidth(column, width: width)
                    },
                    onMoveColumn: { column, left in
                        viewModel.moveGridColumn(column, left: left)
                    }
                )
                if viewModel.canLoadMoreEditorResults || viewModel.isLoadingMore {
                    loadMoreBar
                }
            }
            .sheet(item: $fkPicker) { request in
                ForeignKeyPickerView(
                    title: pickerTitle(for: request),
                    fetch: { search in
                        try await viewModel.fetchReferenceOptions(column: request.column, search: search)
                    },
                    onPick: { value in
                        if let insertId = request.insertId {
                            viewModel.stageInsertCell(insertId: insertId, column: request.column, value: value)
                        } else {
                            viewModel.stageCellChange(
                                column: request.column,
                                newValue: value,
                                rowValues: request.rowValues,
                                columns: request.columns
                            )
                        }
                    }
                )
            }
            .sheet(item: $valueViewer) { request in
                CellValueViewerSheet(column: request.column, value: request.value)
            }
        } else {
            AppEmptyState(
                icon: viewModel.selectedSQLiteTable == nil ? "tablecells" : "tray",
                title: viewModel.selectedSQLiteTable == nil
                    ? pluginLocalization.string("Select a table")
                    : pluginLocalization.string("No results"),
                description: viewModel.selectedSQLiteTable == nil
                    ? pluginLocalization.string("Choose a table from the sidebar to view its data.")
                    : nil
            )
        }
    }

    // MARK: - Error banner with recovery action

    private func errorBanner(for classified: ClassifiedDatabaseError) -> some View {
        DatabaseErrorBannerView(viewModel: viewModel, classified: classified)
    }

    // MARK: - FK picker

    private func pickerTitle(for request: FKPickerRequest) -> String {
        guard let refTable = viewModel.foreignKey(for: request.column)?.referencesTable else {
            return request.column
        }
        return "\(request.column) → \(refTable)"
    }

    // MARK: - Copy

    private func copyToPasteboard(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Load more (editor result row cap)

    private var loadMoreBar: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.editorFetchedRows) \(pluginLocalization.string("rows"))")
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if viewModel.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            }
            AppButton(
                pluginLocalization.string("Load More"),
                systemImage: "arrow.down.circle",
                style: .secondary,
                size: .small,
                action: { Task { await viewModel.loadMoreEditorResults() } }
            )
            .disabled(viewModel.isLoadingMore)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Material.regularMaterial)
    }

    // MARK: - Multi-execution tab bar

    private var multiExecutionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(viewModel.multiExecutions.enumerated()), id: \.element.id) { index, exec in
                    tabButton(index: index, execution: exec)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 34)
        .background(Material.regularMaterial)
    }

    private func tabButton(index: Int, execution: StatementExecution) -> some View {
        let isSelected = viewModel.selectedExecutionIndex == index
        let title = tabTitle(index: index, sql: execution.sql)
        return Button {
            viewModel.selectedExecutionIndex = index
            viewModel.queryResult = execution.result
        } label: {
            HStack(spacing: 4) {
                Image(systemName: execution.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(execution.succeeded ? theme.success : theme.error)
                Text(title)
                    .font(.appMicro)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(theme.textPrimary)
                Text(String(format: "%.0f ms", execution.durationMs))
                    .font(.appMicro)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? theme.primary.opacity(0.15) : Color.clear)
            .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func tabTitle(index: Int, sql: String) -> String {
        let firstLine = sql.split(separator: "\n").first.map(String.init) ?? sql
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        let preview: String
        if trimmed.count > 28 {
            preview = String(trimmed.prefix(28)) + "…"
        } else {
            preview = trimmed
        }
        return "#\(index + 1) \(preview)"
    }

    // MARK: - Selected result (in multi-exec)

    @ViewBuilder
    private var selectedResultContent: some View {
        let idx = viewModel.selectedExecutionIndex
        if idx >= 0, idx < viewModel.multiExecutions.count {
            let exec = viewModel.multiExecutions[idx]
            if let err = exec.errorMessage {
                let title = pluginLocalization.string((exec.errorCategory ?? .unknown).localizationKey)
                AppErrorBanner(message: LocalizedStringKey(err.isEmpty ? title : "\(title): \(err)"))
                    .padding(12)
            } else if let result = exec.result {
                QueryResultView(result: result, nullText: viewModel.useNullSymbol ? "⟨NULL⟩" : "NULL")
            } else {
                AppEmptyState(icon: "tray", title: pluginLocalization.string("No results"))
            }
        } else {
            AppEmptyState(icon: "tray", title: pluginLocalization.string("No results"))
        }
    }
}

// MARK: - 预览

#if DEBUG
#Preview("Results - Idle") {
    QueryResultSectionView(viewModel: DatabaseViewModel(loadSavedConfigs: false))
        .frame(width: 600, height: 300)
}
#endif
