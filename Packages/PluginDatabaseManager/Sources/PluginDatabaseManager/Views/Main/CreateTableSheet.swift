import LumiUI
import SwiftUI

/// 建表表单：列（内联编辑）/复合主键/索引/外键 → 实时 DDL 预览 → 经写闸门执行。
/// 复用 ``CreateTableDDLGenerator`` 生成跨引擎 DDL，执行走 ``DatabaseViewModel/createTable(_:)``。
struct CreateTableSheet: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var isPresented: Bool

    @State private var draft = NewTableDraft()
    @State private var showAddIndex = false
    @State private var showAddForeignKey = false

    private var columnNames: [String] { draft.columns.map(\.name) }
    private var canCreate: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.columns.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameSection
                    columnsSection
                    primaryKeySection
                    indexesSection
                    foreignKeysSection
                    previewSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let error = viewModel.createTableError {
                AppErrorBanner(message: LocalizedStringKey(error))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            AppDivider()
            footer
        }
        .frame(width: 680, height: 660)
        .appSurface(style: .toolbar)
        .onChange(of: columnNames) { _, _ in pruneReferences() }
        .sheet(isPresented: $showAddIndex) {
            AddSchemaIndexSheet(isPresented: $showAddIndex, availableColumns: columnNames) { index in
                draft.indexes.append(index)
            }
        }
        .sheet(isPresented: $showAddForeignKey) {
            AddForeignKeySheet(isPresented: $showAddForeignKey, availableColumns: columnNames) { foreignKey in
                draft.foreignKeys.append(foreignKey)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells.badge.ellipsis")
                .foregroundStyle(theme.primary)
            Text(pluginLocalization.string("New Table"))
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
            Spacer()
            AppButton(pluginLocalization.string("Close"), style: .ghost, size: .small) { isPresented = false }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var nameSection: some View {
        GlassTextField(title: pluginLocalization.string("Table Name"), text: $draft.name, placeholder: "orders")
    }

    private var columnsSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(pluginLocalization.string("Columns"), systemImage: "rectangle.split.3x1") {
                    draft.columns.append(NewTableColumnDraft(name: "", dataType: defaultColumnType, isNullable: true))
                }
                if draft.columns.isEmpty {
                    Text(pluginLocalization.string("Add at least one column."))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(draft.columns.indices, id: \.self) { index in
                    columnRow(index)
                    if index < draft.columns.count - 1 { AppDivider() }
                }
            }
        }
    }

    private func columnRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(pluginLocalization.string("Name"), text: $draft.columns[index].name)
                    .textFieldStyle(.roundedBorder)
                    .font(.appBody)
                TextField(pluginLocalization.string("Data Type"), text: $draft.columns[index].dataType)
                    .textFieldStyle(.roundedBorder)
                    .font(.appBody)
                    .frame(width: 140)
                AppIconButton(systemImage: "trash", label: pluginLocalization.string("Remove Column"), size: .compact) {
                    draft.columns.remove(at: index)
                }
            }
            HStack(spacing: 12) {
                Toggle(pluginLocalization.string("Allow NULL"), isOn: $draft.columns[index].isNullable)
                    .toggleStyle(.checkbox)
                    .font(.appCaption)
                TextField(pluginLocalization.string("Default SQL Expression"), text: Binding(
                    get: { draft.columns[index].defaultValue ?? "" },
                    set: { draft.columns[index].defaultValue = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.appCaption)
            }
        }
    }

    private var primaryKeySection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(pluginLocalization.string("Primary Key"), systemImage: "key") {}
                if columnNames.isEmpty {
                    Text(pluginLocalization.string("Define columns first."))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(columnNames, id: \.self) { name in
                        Toggle(name, isOn: primaryKeyBinding(name))
                            .toggleStyle(.checkbox)
                            .font(.appBody)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var indexesSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(pluginLocalization.string("Indexes"), systemImage: "list.number") {
                    showAddIndex = true
                }
                .disabled(columnNames.isEmpty)
                if draft.indexes.isEmpty {
                    Text(pluginLocalization.string("No indexes"))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(draft.indexes.indices, id: \.self) { index in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.indexes[index].name).font(.appMicroEmphasized)
                            Text(draft.indexes[index].columns.joined(separator: ", "))
                                .font(.appMicro).foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        AppTag(draft.indexes[index].isUnique ? "UNIQUE" : "INDEX", style: .subtle)
                        AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Remove Index"), size: .compact) {
                            draft.indexes.remove(at: index)
                        }
                    }
                }
            }
        }
    }

    private var foreignKeysSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(pluginLocalization.string("Foreign Keys"), systemImage: "link") {
                    showAddForeignKey = true
                }
                .disabled(columnNames.isEmpty)
                if draft.foreignKeys.isEmpty {
                    Text(pluginLocalization.string("No foreign keys"))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(draft.foreignKeys.indices, id: \.self) { index in
                    let foreignKey = draft.foreignKeys[index]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(foreignKey.columns.joined(separator: ", ")) → \(foreignKey.referencedTable).\(foreignKey.referencedColumns.joined(separator: ", "))")
                                .font(.appMicroEmphasized)
                            Text([foreignKey.onDelete.map { "ON DELETE \($0)" }, foreignKey.onUpdate.map { "ON UPDATE \($0)" }].compactMap { $0 }.joined(separator: "  "))
                                .font(.appMicro).foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Remove Foreign Key"), size: .compact) {
                            draft.foreignKeys.remove(at: index)
                        }
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(pluginLocalization.string("DDL Preview"))
                    .font(.appMicroEmphasized)
                    .foregroundStyle(theme.textSecondary)
                ScrollView {
                    Text(canCreate ? viewModel.createTablePreview(draft) : pluginLocalization.string("Name the table and add columns to preview the DDL."))
                        .font(.monospaced(.callout)())
                        .foregroundColor(theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 180)
            }
        }
    }

    private var footer: some View {
        HStack {
            if viewModel.isCreatingTable {
                ProgressView().controlSize(.small)
                Text(pluginLocalization.string("Creating…"))
                    .font(.appCaption).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            AppButton(pluginLocalization.string("Cancel"), style: .secondary, size: .small) { isPresented = false }
            AppButton(pluginLocalization.string("Create Table"), systemImage: "plus", style: .primary, size: .small) {
                Task { await viewModel.createTable(draft) }
            }
            .disabled(!canCreate || viewModel.isCreatingTable)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, systemImage: String, onAdd: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(theme.primary)
            Text(title).font(.appBodyEmphasized).foregroundColor(theme.textPrimary)
            Spacer()
            AppIconButton(systemImage: "plus", label: title, size: .compact, action: onAdd)
        }
    }

    private var defaultColumnType: String {
        switch viewModel.selectedConfig?.type {
        case .mysql: return "VARCHAR(255)"
        case .postgresql: return "TEXT"
        default: return "TEXT"
        }
    }

    private func primaryKeyBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { draft.primaryKey.contains(name) },
            set: { on in
                if on {
                    if !draft.primaryKey.contains(name) { draft.primaryKey.append(name) }
                } else {
                    draft.primaryKey.removeAll { $0 == name }
                }
            }
        )
    }

    /// 列改名/删除后清理引用了不存在列的主键/索引/外键，避免草稿滞留无效引用。
    private func pruneReferences() {
        let names = Set(columnNames.map { $0.lowercased() })
        draft.primaryKey = draft.primaryKey.filter { names.contains($0.lowercased()) }
        draft.indexes = draft.indexes.filter { index in
            !index.columns.isEmpty && index.columns.allSatisfy { names.contains($0.lowercased()) }
        }
        draft.foreignKeys = draft.foreignKeys.filter { foreignKey in
            !foreignKey.columns.isEmpty && foreignKey.columns.allSatisfy { names.contains($0.lowercased()) }
        }
    }
}

/// 新建表外键草稿表单：本表列（多选）→ 引用表/列（逗号分隔）+ ON DELETE/UPDATE 动作。
private struct AddForeignKeySheet: View {
    @Binding var isPresented: Bool
    let availableColumns: [String]
    let onAdd: (NewTableForeignKeyDraft) throws -> Void

    @State private var selectedColumns: Set<String> = []
    @State private var referencedTable = ""
    @State private var referencedColumnsText = ""
    @State private var onDelete = ""
    @State private var onUpdate = ""
    @State private var errorMessage: String?

    private static let actions = ["", "CASCADE", "SET NULL", "SET DEFAULT", "RESTRICT", "NO ACTION"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pluginLocalization.string("Add Foreign Key")).font(.title3.weight(.semibold))
            Form {
                TextField(pluginLocalization.string("Referenced Table"), text: $referencedTable)
                TextField(pluginLocalization.string("Referenced Columns (comma-separated)"), text: $referencedColumnsText)
                Picker(pluginLocalization.string("On Delete"), selection: $onDelete) {
                    ForEach(Self.actions, id: \.self) { action in
                        Text(action.isEmpty ? pluginLocalization.string("Default") : action).tag(action)
                    }
                }
                Picker(pluginLocalization.string("On Update"), selection: $onUpdate) {
                    ForEach(Self.actions, id: \.self) { action in
                        Text(action.isEmpty ? pluginLocalization.string("Default") : action).tag(action)
                    }
                }
            }
            .formStyle(.grouped)
            Text(pluginLocalization.string("Columns")).font(.appCaption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(availableColumns, id: \.self) { column in
                        Toggle(column, isOn: Binding(
                            get: { selectedColumns.contains(column) },
                            set: { selected in
                                if selected { selectedColumns.insert(column) } else { selectedColumns.remove(column) }
                            }
                        ))
                        .disabled(column.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .frame(maxHeight: 160)
            if let errorMessage { Text(errorMessage).font(.appCaption).foregroundStyle(.red) }
            HStack {
                Spacer()
                AppButton(pluginLocalization.string("Cancel"), style: .secondary, size: .small) { isPresented = false }
                AppButton(pluginLocalization.string("Stage Foreign Key"), systemImage: "plus", style: .primary, size: .small) {
                    let columns = availableColumns.filter(selectedColumns.contains)
                    let referencedColumns = referencedColumnsText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let foreignKey = NewTableForeignKeyDraft(
                        columns: columns,
                        referencedTable: referencedTable,
                        referencedColumns: referencedColumns,
                        onDelete: onDelete.isEmpty ? nil : onDelete,
                        onUpdate: onUpdate.isEmpty ? nil : onUpdate
                    )
                    do {
                        guard !referencedTable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw CreateTableValidationError.foreignKeyBlankTable
                        }
                        guard !columns.isEmpty, columns.count == referencedColumns.count else {
                            throw CreateTableValidationError.foreignKeyColumnMismatch
                        }
                        try onAdd(foreignKey)
                        isPresented = false
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}