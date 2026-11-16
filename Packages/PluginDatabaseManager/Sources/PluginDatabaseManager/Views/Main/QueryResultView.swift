import SwiftUI
import LumiUI

/// 查询结果的表格渲染视图。
///
/// 由 ``QueryResultSectionView`` 在 `viewModel.queryResult` 非空时调用，
/// 渲染一个 ScrollView 包住 LazyVStack 的表格视图：
/// - 列头通过 `pinnedViews: [.sectionHeaders]` 在纵向滚动时钉在视口顶部；
/// - 每列固定宽度 `columnWidth`，列多时可横向滚动；
/// - 单元格支持右键复制内容到剪贴板。
struct QueryResultView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    // MARK: - Properties

    let result: QueryResult
    /// 当前排序列（nil 表示未排序）。
    var sortColumn: String? = nil
    /// 排序方向（仅在 sortColumn 非空时有意义）。
    var sortAscending: Bool = true
    /// 表头点击回调；nil 时表头不可点击。
    var onToggleSort: ((String) -> Void)? = nil
    /// 变更跟踪器；非空且可编辑时单元格支持双击编辑与高亮。
    var changeManager: TableChangeManager? = nil
    /// 单元格提交回调：(列名, 当前行, 全部列名, 新值)。
    var onStageChange: ((String, [DatabaseValue], [String], DatabaseValue) -> Void)? = nil
    /// 新增行列提交回调：(insertId, 列名, 新值)。
    var onStageInsertChange: ((UUID, String, DatabaseValue) -> Void)? = nil
    /// 切换行删除回调：(行值, 列名)。
    var onToggleRowDeletion: (([DatabaseValue], [String]) -> Void)? = nil
    /// 移除未保存新增行回调。
    var onRemoveInsert: ((UUID) -> Void)? = nil
    /// NULL 单元格的显示文本（可配置为 ⟨NULL⟩）。
    var nullText: String = "NULL"
    /// 置回数据库默认值回调：(列名, 当前行, 全部列名)。
    var onStageDefault: ((String, [DatabaseValue], [String]) -> Void)? = nil
    /// 新增行某列恢复为「使用数据库默认值」回调：(insertId, 列名)。
    var onClearInsertColumn: ((UUID, String) -> Void)? = nil
    /// 外键选值回调：(列名, 当前行, 全部列名)。
    var onChooseReference: ((String, [DatabaseValue], [String]) -> Void)? = nil
    /// 跳转到引用行回调：(列名, 当前行, 全部列名)。
    var onJumpToReference: ((String, [DatabaseValue], [String]) -> Void)? = nil
    /// 新增行外键选值回调：(insertId, 列名)。
    var onChooseInsertReference: ((UUID, String) -> Void)? = nil
    /// 行级复制回调：(格式, 行值, 列名)。
    var onCopyRowAs: ((GridRowCopyKind, [DatabaseValue], [String]) -> Void)? = nil
    /// IN 列表复制回调：(列名)。
    var onCopyInList: ((String) -> Void)? = nil
    /// 页级复制回调：(格式)。
    var onCopyPageAs: ((GridPageCopyKind) -> Void)? = nil
    /// UPDATE 复制是否可用（存在行键）。
    var canCopyUpdate: Bool = false
    /// 值查看器回调：(列名, 显示值)。
    var onViewValue: ((String, DatabaseValue) -> Void)? = nil
    /// 用户列宽覆盖（按列名）；优先于内容估算宽度。
    var columnWidthOverrides: [String: CGFloat] = [:]
    /// 用户列顺序（列名序列）；nil 表示自然顺序。
    var displayColumnOrder: [String]? = nil
    /// 列宽调整回调：(列名, 新宽度)。
    var onResizeColumn: ((String, CGFloat) -> Void)? = nil
    /// 列移动回调：(列名, 是否左移)。
    var onMoveColumn: ((String, Bool) -> Void)? = nil
    /// 查找匹配的单元格位置集合（高亮显示）。
    var findMatches: Set<GridFind.CellPosition> = []
    /// 当前活动查找匹配（更强高亮）。
    var activeFindMatch: GridFind.CellPosition? = nil

    // MARK: - Editing state

    private struct CellKey: Hashable { let row: Int; let col: Int }
    private struct InsertCellKey: Hashable { let insertId: UUID; let column: String }
    @State private var editingCell: CellKey? = nil
    @State private var editText: String = ""
    @State private var editingInsert: InsertCellKey? = nil
    @State private var editInsertText: String = ""
    /// 正在拖拽调整宽度的列名（nil 表示无）。
    @State private var resizingColumn: String? = nil
    /// 拖拽起始宽度与实时宽度。
    @State private var resizeStartWidth: CGFloat = 0
    @State private var resizeLiveWidth: CGFloat = 0
    /// 选中的单元格（单击选择，⌘ 单击增减，⇧ 单击矩形范围）。
    @State private var selectedCells: Set<CellKey> = []
    /// 范围选择的锚点单元格。
    @State private var selectionAnchor: CellKey? = nil

    // MARK: - Constants

    /// 行号列宽度。
    private static let rowNumberWidth: CGFloat = 44

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(0 ..< result.rows.count, id: \.self) { rowIndex in
                                resultRow(at: rowIndex)
                            }
                            if let cm = changeManager, !cm.pendingInserts.isEmpty {
                                ForEach(cm.pendingInserts) { insert in
                                    insertedRow(insert)
                                }
                            }
                        } header: {
                            headerRow
                        }

                        Spacer()
                    }
                    // 内容比视口小时：撑满视口并靠左上对齐；比视口大时：自然产生横/纵滚动。
                    .frame(
                        minWidth: max(proxy.size.width, tableWidth),
                        minHeight: proxy.size.height,
                        alignment: .topLeading
                    )
                }
            }
            if !selectedCells.isEmpty {
                selectionSummaryBar
                AppDivider()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection summary

    /// 选区摘要条：选中单元格数 + 数值列 sum/avg。
    private var selectionSummaryBar: some View {
        let positions = Set(selectedCells.map { GridFind.CellPosition(row: $0.row, col: $0.col) })
        let summary = GridSelectionSummary.compute(positions: positions) { pos in
            guard pos.row < result.rows.count, pos.col < result.columns.count else { return .null }
            let row = result.rows[pos.row]
            guard pos.col < row.count else { return .null }
            return displayedValue(row: row, column: result.columns[pos.col])
        }
        return HStack(spacing: 12) {
            Image(systemName: "selection.pin.in.out")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.primary)
            Text("\(summary.cellCount) \(pluginLocalization.string("selected"))")
                .font(.appMicroEmphasized)
                .foregroundStyle(theme.textPrimary)
            if summary.hasNumeric {
                Text(pluginLocalization.string("Sum") + ": \(formattedNumber(summary.sum))")
                    .font(.appMicro)
                    .foregroundStyle(theme.textSecondary)
                Text(pluginLocalization.string("Avg") + ": \(formattedNumber(summary.average ?? 0))")
                    .font(.appMicro)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            AppIconButton(systemImage: "xmark.circle", label: pluginLocalization.string("Clear Selection"), size: .compact) {
                selectedCells = []
                selectionAnchor = nil
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(theme.primary.opacity(0.06))
    }

    /// 摘要数值显示：整数去小数，浮点保留至多 4 位。
    private func formattedNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.4g", value)
    }

    /// 处理单元格单击选择（⌘ 增减、⇧ 矩形范围、普通单击替换）。
    private func handleCellTap(row: Int, col: Int) {
        let key = CellKey(row: row, col: col)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selectedCells.contains(key) { selectedCells.remove(key) } else { selectedCells.insert(key) }
            selectionAnchor = key
        } else if flags.contains(.shift), let anchor = selectionAnchor {
            let r0 = min(anchor.row, row), r1 = max(anchor.row, row)
            let c0 = min(anchor.col, col), c1 = max(anchor.col, col)
            for r in r0 ... r1 {
                for c in c0 ... c1 { selectedCells.insert(CellKey(row: r, col: c)) }
            }
        } else {
            selectedCells = [key]
            selectionAnchor = key
        }
    }

    /// 单元格背景色：活动查找 > 选中 > 查找匹配 > 已编辑。
    private func cellBackground(isChanged: Bool, isSelected: Bool, isFindMatch: Bool, isActiveFind: Bool) -> Color {
        if isActiveFind { return theme.primary.opacity(0.35) }
        if isSelected { return theme.primary.opacity(0.18) }
        if isFindMatch { return theme.primary.opacity(0.12) }
        if isChanged { return theme.warning.opacity(0.18) }
        return Color.clear
    }

    // MARK: - Layout

    /// 行号列 + 各数据列宽度之和（按显示顺序）。
    private var tableWidth: CGFloat {
        Self.rowNumberWidth + orderedColumnIndices.reduce(0) { $0 + displayWidth(for: $1) }
    }

    /// 显示顺序对应的数据列索引（应用持久化列序）。
    private var orderedColumnIndices: [Int] {
        GridColumnLayout.orderedIndices(columns: result.columns, order: displayColumnOrder)
    }

    /// 按列名 + 前 50 行内容估算的列宽（有界采样，百万行不劣化）。
    private var estimatedWidths: [CGFloat] {
        GridColumnLayout.estimateWidths(columns: result.columns, rows: result.rows) { content(for: $0) }
    }

    /// 某数据列的基础宽度：用户覆盖优先，否则内容估算。
    private func width(for colIndex: Int) -> CGFloat {
        columnWidthOverrides[result.columns[colIndex]] ?? estimatedWidths[colIndex]
    }

    /// 某数据列的当前显示宽度：拖拽中的列用实时宽度。
    private func displayWidth(for colIndex: Int) -> CGFloat {
        if resizingColumn == result.columns[colIndex] { return resizeLiveWidth }
        return width(for: colIndex)
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.appMicroEmphasized)
                .foregroundStyle(.secondary)
                .frame(width: Self.rowNumberWidth, alignment: .center)
                .border(theme.appSubtleBorder)
            ForEach(orderedColumnIndices, id: \.self) { colIndex in
                headerCell(for: colIndex)
            }
            Spacer(minLength: 0)
        }
        .background(Material.regularMaterial)
    }

    @ViewBuilder
    private func headerCell(for colIndex: Int) -> some View {
        let name = result.columns[colIndex]
        let isSorted = (sortColumn == name)
        let cellWidth = displayWidth(for: colIndex)
        let label = HStack(spacing: 4) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            if isSorted {
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            Spacer(minLength: 0)
        }
        .font(.appBodyEmphasized)
        .foregroundColor(theme.textPrimary)
        .padding(8)
        .frame(width: cellWidth, alignment: .leading)
        .border(theme.appSubtleBorder)
        .contextMenu {
            if let onMoveColumn {
                Button(pluginLocalization.string("Move Left")) { onMoveColumn(name, true) }
                Button(pluginLocalization.string("Move Right")) { onMoveColumn(name, false) }
            }
        }

        ZStack(alignment: .trailing) {
            if let onToggleSort {
                Button(action: { onToggleSort(name) }) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
            if onResizeColumn != nil {
                resizeHandle(for: name, colIndex: colIndex)
            }
        }
        .frame(width: cellWidth)
    }

    /// 列宽拖拽手柄：拖拽中实时更新显示宽度，结束时回调持久化。
    private func resizeHandle(for name: String, colIndex: Int) -> some View {
        Rectangle()
            .fill(theme.appSubtleBorder)
            .frame(width: 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if resizingColumn != name {
                            resizingColumn = name
                            resizeStartWidth = width(for: colIndex)
                        }
                        resizeLiveWidth = GridColumnLayout.clampWidth(resizeStartWidth + value.translation.width)
                    }
                    .onEnded { _ in
                        if resizingColumn == name {
                            onResizeColumn?(name, resizeLiveWidth)
                        }
                        resizingColumn = nil
                    }
            )
    }

    private func resultRow(at rowIndex: Int) -> some View {
        let row = result.rows[rowIndex]
        let isDeleted = changeManager?.isRowDeleted(rowValues: row, columns: result.columns) ?? false
        return HStack(spacing: 0) {
            Text("\(rowIndex + 1)")
                .font(.appMicro)
                .foregroundStyle(isDeleted ? theme.error : .secondary)
                .frame(width: Self.rowNumberWidth, alignment: .center)
                .background(isDeleted ? theme.error.opacity(0.1) : Color.secondary.opacity(0.04))
                .border(theme.appSubtleBorder.opacity(0.7))

            ForEach(orderedColumnIndices.filter { $0 < row.count }, id: \.self) { colIndex in
                cellView(row: row, rowIndex: rowIndex, colIndex: colIndex, width: displayWidth(for: colIndex))
                    .strikethrough(isDeleted)
                    .opacity(isDeleted ? 0.55 : 1)
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            if let onCopyRowAs {
                Menu(pluginLocalization.string("Copy Row As")) {
                    rowCopyButtons(row: row, onCopyRowAs: onCopyRowAs)
                }
            }
            if let onCopyPageAs {
                Menu(pluginLocalization.string("Copy Page As")) {
                    Button(pluginLocalization.string("CSV with Headers")) {
                        onCopyPageAs(.csv)
                    }
                    Button(pluginLocalization.string("Markdown Table")) {
                        onCopyPageAs(.markdown)
                    }
                }
            }
            if changeManager?.isEditable == true {
                if isDeleted {
                    Button(pluginLocalization.string("Undelete Row")) {
                        onToggleRowDeletion?(row, result.columns)
                    }
                } else {
                    Button(role: .destructive) {
                        onToggleRowDeletion?(row, result.columns)
                    } label: {
                        Label(pluginLocalization.string("Delete Row"), systemImage: "trash")
                    }
                }
            }
        }
    }

    /// 行级复制格式按钮（单元格与行右键菜单共用）。
    @ViewBuilder
    private func rowCopyButtons(
        row: [DatabaseValue],
        onCopyRowAs: @escaping (GridRowCopyKind, [DatabaseValue], [String]) -> Void
    ) -> some View {
        Button(pluginLocalization.string("JSON Row")) {
            onCopyRowAs(.json, row, result.columns)
        }
        Button(pluginLocalization.string("CSV Row")) {
            onCopyRowAs(.csv, row, result.columns)
        }
        Button(pluginLocalization.string("INSERT Statement")) {
            onCopyRowAs(.insert, row, result.columns)
        }
        Button(pluginLocalization.string("UPDATE Statement")) {
            onCopyRowAs(.update, row, result.columns)
        }
        .disabled(!canCopyUpdate)
    }

    /// 渲染一条未保存的新增行（行号显示 "+"）。
    private func insertedRow(_ insert: TableChangeManager.PendingInsert) -> some View {
        return HStack(spacing: 0) {
            Text("+")
                .font(.appMicroEmphasized)
                .foregroundStyle(theme.success)
                .frame(width: Self.rowNumberWidth, alignment: .center)
                .background(theme.success.opacity(0.08))
                .border(theme.appSubtleBorder.opacity(0.7))

            ForEach(orderedColumnIndices, id: \.self) { colIndex in
                insertCellView(insert: insert, column: result.columns[colIndex], width: displayWidth(for: colIndex))
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button(role: .destructive) {
                onRemoveInsert?(insert.id)
            } label: {
                Label(pluginLocalization.string("Remove Row"), systemImage: "minus.circle")
            }
        }
    }

    @ViewBuilder
    private func insertCellView(insert: TableChangeManager.PendingInsert, column: String, width: CGFloat) -> some View {
        let key = InsertCellKey(insertId: insert.id, column: column)
        if editingInsert == key {
            TypedCellEditor(
                kind: editorKind(for: column),
                width: width,
                text: $editInsertText,
                onCommit: { commitInsertEdit(insertId: insert.id, column: column) },
                onCancel: { editingInsert = nil }
            )
        } else {
            let usesDefault = changeManager?.insertUsesDefault(insertId: insert.id, column: column) ?? false
            let value = changeManager?.insertDisplayValue(insertId: insert.id, column: column) ?? .null
            let text = usesDefault ? "DEFAULT" : content(for: value)
            Text(text)
                .font(.monospaced(.body)())
                .foregroundColor(usesDefault || value == .null ? theme.textTertiary : theme.textPrimary)
                .italic(usesDefault || value == .null)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(8)
                .frame(width: width, alignment: .leading)
                .background(theme.success.opacity(0.06))
                .border(theme.appSubtleBorder.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    editInsertText = usesDefault ? "" : editRepresentation(for: value)
                    editingInsert = key
                }
                .contextMenu {
                    if let onChooseInsertReference, canPickReference(for: column) {
                        Button(pluginLocalization.string("Choose Reference…")) {
                            onChooseInsertReference(insert.id, column)
                        }
                    }
                    Button(pluginLocalization.string("Set NULL")) {
                        onStageInsertChange?(insert.id, column, .null)
                    }
                    Button(pluginLocalization.string("Set Default")) {
                        onClearInsertColumn?(insert.id, column)
                    }
                    if editorKind(for: column) == .text {
                        Button(pluginLocalization.string("Set Empty String")) {
                            onStageInsertChange?(insert.id, column, .string(""))
                        }
                    }
                }
        }
    }

    private func commitInsertEdit(insertId: UUID, column: String) {
        let original = changeManager?.insertDisplayValue(insertId: insertId, column: column)
        let value = parseEditedCellValue(editInsertText, columnType: changeManager?.columnType(of: column), original: original)
        onStageInsertChange?(insertId, column, value)
        editingInsert = nil
    }

    @ViewBuilder
    private func cellView(row: [DatabaseValue], rowIndex: Int, colIndex: Int, width: CGFloat) -> some View {
        let column = result.columns[colIndex]
        let displayed = displayedValue(row: row, column: column)
        let isChanged = changeManager?.isCellChanged(column: column, rowValues: row, columns: result.columns) ?? false
        let isDefault = changeManager?.isCellDefault(column: column, rowValues: row, columns: result.columns) ?? false
        let isNull = displayed == .null
        let key = CellKey(row: rowIndex, col: colIndex)
        let position = GridFind.CellPosition(row: rowIndex, col: colIndex)
        let isSelected = selectedCells.contains(key)
        let isFindMatch = findMatches.contains(position)
        let isActiveFind = activeFindMatch == position

        if editingCell == key {
            TypedCellEditor(
                kind: editorKind(for: column),
                width: width,
                text: $editText,
                onCommit: { commitEdit(row: row, column: column) },
                onCancel: { editingCell = nil }
            )
        } else {
            let text = isDefault ? "DEFAULT" : content(for: displayed)
            Text(text)
                .font(.monospaced(.body)())
                .foregroundColor(isDefault ? theme.warning : (isNull ? theme.textTertiary : theme.textPrimary))
                .italic(isNull || isDefault)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(8)
                .frame(width: width, alignment: .leading)
                .background(cellBackground(isChanged: isChanged, isSelected: isSelected, isFindMatch: isFindMatch, isActiveFind: isActiveFind))
                .border(isSelected ? theme.primary.opacity(0.6) : theme.appSubtleBorder.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard changeManager?.isEditable == true else { return }
                    editText = isDefault ? "" : editRepresentation(for: displayed)
                    editingCell = key
                }
                .onTapGesture(count: 1) {
                    handleCellTap(row: rowIndex, col: colIndex)
                }
                .contextMenu {
                    Button(pluginLocalization.string("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    if let onCopyRowAs {
                        Menu(pluginLocalization.string("Copy As")) {
                            rowCopyButtons(row: row, onCopyRowAs: onCopyRowAs)
                            if let onCopyInList {
                                Divider()
                                Button(pluginLocalization.string("IN List (Column)")) {
                                    onCopyInList(column)
                                }
                            }
                        }
                    }
                    if let onViewValue {
                        Button(pluginLocalization.string("View Value…")) {
                            onViewValue(column, displayed)
                        }
                    }
                    if changeManager?.isEditable == true {
                        Button(pluginLocalization.string("Set NULL")) {
                            onStageChange?(column, row, result.columns, .null)
                        }
                        Button(pluginLocalization.string("Set Default")) {
                            onStageDefault?(column, row, result.columns)
                        }
                        if editorKind(for: column) == .text {
                            Button(pluginLocalization.string("Set Empty String")) {
                                onStageChange?(column, row, result.columns, .string(""))
                            }
                        }
                        if let onChooseReference, canPickReference(for: column) {
                            Button(pluginLocalization.string("Choose Reference…")) {
                                onChooseReference(column, row, result.columns)
                            }
                        }
                    }
                    if let onJumpToReference, canJumpToReference(row: row, column: column) {
                        Button(pluginLocalization.string("Jump to Referenced Row")) {
                            onJumpToReference(column, row, result.columns)
                        }
                    }
                }
        }
    }

    /// 列的编辑器种类：有变更跟踪器时按 catalog 类型与枚举取值路由，否则按文本。
    private func editorKind(for column: String) -> CellEditorKind {
        guard let cm = changeManager else { return .text }
        return cellEditorKind(for: cm.columnType(of: column) ?? "", enumValues: cm.enumValues(of: column))
    }

    /// 列是否可用引用选择器（单列外键）。
    private func canPickReference(for column: String) -> Bool {
        guard let cm = changeManager,
              let fk = ForeignKeySupport.foreignKey(for: column, in: cm.schema) else { return false }
        return ForeignKeySupport.canPick(fk)
    }

    /// 当前显示值（含暂存编辑）能否定位引用行。
    private func canJumpToReference(row: [DatabaseValue], column: String) -> Bool {
        guard let cm = changeManager,
              let fk = ForeignKeySupport.foreignKey(for: column, in: cm.schema) else { return false }
        let values = fk.columns.map { displayedValue(row: row, column: $0) }
        return ForeignKeySupport.canLocate(fk, values: values)
    }

    /// 显示值：优先取变更队列里的暂存值，否则取结果原始值。
    private func displayedValue(row: [DatabaseValue], column: String) -> DatabaseValue {
        if let cm = changeManager {
            return cm.displayedValue(column: column, rowValues: row, columns: result.columns)
        }
        guard let idx = result.columns.firstIndex(of: column), idx < row.count else { return .null }
        return row[idx]
    }

    private func commitEdit(row: [DatabaseValue], column: String) {
        let original: DatabaseValue? = {
            guard let idx = result.columns.firstIndex(of: column), idx < row.count else { return nil }
            return row[idx]
        }()
        let value = parseEditedCellValue(editText, columnType: changeManager?.columnType(of: column), original: original)
        onStageChange?(column, row, result.columns, value)
        editingCell = nil
    }

    /// 进入编辑时的文本：BLOB 用 hex 表示，保证无损往返。
    private func editRepresentation(for value: DatabaseValue) -> String {
        switch value {
        case .null: return ""
        case .data(let data): return hexEditText(for: data)
        default: return content(for: value)
        }
    }

    // MARK: - Helpers

    private func content(for value: DatabaseValue) -> String {
        switch value {
        case let .integer(v): return String(v)
        case let .double(v): return String(v)
        case let .string(v): return v
        case let .bool(v): return String(v)
        case let .data(v): return "<BLOB \(v.count) bytes>"
        case .null: return nullText
        }
    }
}

// MARK: - 预览

#if DEBUG
#Preview("Empty Table") {
    QueryResultView(
        result: QueryResult(
            columns: ["id", "name", "created_at"],
            rows: [
                [DatabaseValue.integer(1), DatabaseValue.string("Alice"), DatabaseValue.string("2024-01-01")],
                [DatabaseValue.integer(2), DatabaseValue.string("Bob"), DatabaseValue.null]
            ],
            rowsAffected: 0
        )
    )
    .frame(width: 560, height: 240)
}
#endif
