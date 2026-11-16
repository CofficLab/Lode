import LumiUI
import SwiftUI
import UniformTypeIdentifiers

/// 数据导入向导：选文件 → 预览 → 列映射（目标表对齐/跳过）→ 选项 → 批量导入。
/// 解析/推断/执行全部走 ``DatabaseViewModel`` 的导入管线；本视图只负责呈现与收集选择。
struct ImportDataSheet: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var isPresented: Bool

    private enum TargetMode: String, CaseIterable {
        case existingTable
        case newTable
    }

    @State private var fileURL: URL?
    @State private var fileName: String?
    @State private var isChoosingFile = false
    @State private var targetMode: TargetMode = .existingTable
    @State private var targetTables: [DatabaseObject] = []
    @State private var selectedTableID: String?
    @State private var targetColumns: [String] = []
    @State private var newTableName = ""
    @State private var mappings: [ImportColumnMapping] = []
    @State private var emptyAsNull = true
    @State private var badRowStrategy: ImportBadRowStrategy = .skip

    private var supportsNewTable: Bool {
        viewModel.selectedConfig?.type.capabilities.supportsSchemaEditing == true
    }

    private var selectedTable: DatabaseObject? {
        targetTables.first { $0.id == selectedTableID }
    }

    private var mappedCount: Int {
        mappings.count { $0.targetColumn?.isEmpty == false }
    }

    private var hasDuplicateTargets: Bool {
        let targets = mappings.compactMap { $0.targetColumn?.lowercased() }.filter { !$0.isEmpty }
        return Set(targets).count != targets.count
    }

    private var canImport: Bool {
        guard !viewModel.isImporting, !viewModel.importCompleted, mappedCount > 0, !hasDuplicateTargets else { return false }
        switch targetMode {
        case .existingTable: return selectedTable != nil
        case .newTable: return !newTableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            if viewModel.importSourceColumns.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        fileSection
                        previewSection
                        targetSection
                        mappingSection
                        optionsSection
                        if viewModel.importCompleted { completionSection }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if let error = viewModel.importError {
                AppErrorBanner(message: LocalizedStringKey(error))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            AppDivider()
            footer
        }
        .frame(width: 720, height: 640)
        .appSurface(style: .toolbar)
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.commaSeparatedText, .json, .plainText]
        ) { result in
            if case .success(let url) = result {
                Task { await loadFile(url) }
            }
        }
        .onChange(of: viewModel.importHasHeader) { _, _ in
            guard let fileURL, viewModel.importFormat == .csv else { return }
            Task {
                await viewModel.loadImportPreview(url: fileURL)
                rebuildMappings()
            }
        }
        .onChange(of: selectedTableID) { _, newID in
            guard targetMode == .existingTable else { return }
            Task {
                if let newID, let table = targetTables.first(where: { $0.id == newID }) {
                    targetColumns = await viewModel.loadImportTargetColumns(table)
                } else {
                    targetColumns = []
                }
                rebuildMappings()
            }
        }
        .onChange(of: targetMode) { _, _ in
            if targetMode == .newTable { targetColumns = viewModel.importSourceColumns }
            rebuildMappings()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(theme.primary)
            Text(pluginLocalization.string("Import Data"))
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
            Spacer()
            AppButton(pluginLocalization.string("Close"), style: .ghost, size: .small) {
                if viewModel.isImporting { viewModel.cancelImport() }
                isPresented = false
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            AppEmptyState(
                icon: "square.and.arrow.down",
                title: pluginLocalization.string("Import Data"),
                description: pluginLocalization.string("Choose a CSV or JSON file to import.")
            )
            AppButton(pluginLocalization.string("Choose File"), systemImage: "doc", style: .primary, size: .small) {
                isChoosingFile = true
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(theme.textSecondary)
            Text(fileName ?? "")
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let format = viewModel.importFormat {
                AppTag(format.rawValue.uppercased(), style: .subtle)
            }
            Spacer()
            AppButton(pluginLocalization.string("Change File"), style: .secondary, size: .small) {
                isChoosingFile = true
            }
            .disabled(viewModel.isImporting)
        }
    }

    private var previewSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(pluginLocalization.string("Preview"))
                        .font(.appMicroEmphasized)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    if viewModel.importFormat == .csv {
                        Toggle(pluginLocalization.string("First row is header"), isOn: $viewModel.importHasHeader)
                            .toggleStyle(.checkbox)
                            .font(.appCaption)
                            .disabled(viewModel.isImporting)
                    }
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.importSourceColumns, id: \.self) { column in
                                Text(column)
                                    .font(.appMicroEmphasized)
                                    .foregroundColor(theme.textPrimary)
                                    .frame(width: 110, alignment: .leading)
                                    .lineLimit(1)
                            }
                        }
                        AppDivider()
                        ForEach(Array(viewModel.importPreviewRows.prefix(8).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    previewCell(cell)
                                        .frame(width: 110, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
        }
    }

    @ViewBuilder
    private func previewCell(_ cell: ImportCell) -> some View {
        switch cell {
        case .text(let value):
            Text(value)
                .font(.monospaced(.caption)())
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        case .null:
            Text("NULL")
                .font(.monospaced(.caption)())
                .italic()
                .foregroundColor(theme.textTertiary)
                .lineLimit(1)
        case .missing:
            Text("—")
                .font(.monospaced(.caption)())
                .foregroundColor(theme.textTertiary)
                .lineLimit(1)
        }
    }

    private var targetSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(pluginLocalization.string("Target"))
                    .font(.appMicroEmphasized)
                    .foregroundStyle(theme.textSecondary)
                Picker(pluginLocalization.string("Target"), selection: $targetMode) {
                    Text(pluginLocalization.string("Existing Table")).tag(TargetMode.existingTable)
                    if supportsNewTable {
                        Text(pluginLocalization.string("New Table")).tag(TargetMode.newTable)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(viewModel.isImporting || viewModel.importCompleted)
                switch targetMode {
                case .existingTable:
                    if targetTables.isEmpty {
                        Text(pluginLocalization.string("No tables available"))
                            .font(.appCaption)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        Picker(pluginLocalization.string("Select a table"), selection: $selectedTableID) {
                            Text(pluginLocalization.string("Select a table")).tag(String?.none)
                            ForEach(targetTables, id: \.id) { table in
                                Text(table.name).tag(String?.some(table.id))
                            }
                        }
                        .labelsHidden()
                        .disabled(viewModel.isImporting || viewModel.importCompleted)
                    }
                case .newTable:
                    GlassTextField(title: pluginLocalization.string("Table Name"), text: $newTableName, placeholder: "imported_data")
                        .disabled(viewModel.isImporting || viewModel.importCompleted)
                }
            }
        }
    }

    private var mappingSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(pluginLocalization.string("Column Mapping"))
                    .font(.appMicroEmphasized)
                    .foregroundStyle(theme.textSecondary)
                HStack(spacing: 8) {
                    Text(pluginLocalization.string("Source Column"))
                        .frame(width: 180, alignment: .leading)
                    Text(pluginLocalization.string("Target Column"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.appMicro)
                .foregroundStyle(theme.textTertiary)
                ForEach(mappings.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text(mappings[index].sourceColumn)
                            .font(.appBody)
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                            .frame(width: 140, alignment: .leading)
                        AppTag(mappings[index].inferredType.rawValue, style: .subtle)
                        Picker(pluginLocalization.string("Target Column"), selection: $mappings[index].targetColumn) {
                            Text(pluginLocalization.string("Skip")).tag(String?.none)
                            ForEach(targetColumns, id: \.self) { column in
                                Text(column).tag(String?.some(column))
                            }
                        }
                        .labelsHidden()
                        .disabled(viewModel.isImporting || viewModel.importCompleted)
                    }
                    if index < mappings.count - 1 { AppDivider() }
                }
            }
        }
    }

    private var optionsSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(pluginLocalization.string("Empty values as NULL"), isOn: $emptyAsNull)
                    .toggleStyle(.checkbox)
                    .font(.appBody)
                    .disabled(viewModel.isImporting || viewModel.importCompleted)
                HStack(spacing: 8) {
                    Text(pluginLocalization.string("On bad rows"))
                        .font(.appBody)
                        .foregroundColor(theme.textPrimary)
                    Picker(pluginLocalization.string("On bad rows"), selection: $badRowStrategy) {
                        Text(pluginLocalization.string("Skip and report")).tag(ImportBadRowStrategy.skip)
                        Text(pluginLocalization.string("Abort")).tag(ImportBadRowStrategy.abort)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(viewModel.isImporting || viewModel.importCompleted)
                }
            }
        }
    }

    private var completionSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                    Text(pluginLocalization.string("Import complete."))
                        .font(.appBodyEmphasized)
                        .foregroundColor(theme.textPrimary)
                    Text("\(viewModel.importedRowCount) " + pluginLocalization.string("rows"))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                }
                if !viewModel.importBadRows.isEmpty {
                    Text(pluginLocalization.string("Bad Rows") + " (\(viewModel.importBadRows.count))")
                        .font(.appMicroEmphasized)
                        .foregroundStyle(theme.warning)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(viewModel.importBadRows.enumerated()), id: \.offset) { _, badRow in
                                Text("\(badRow.rowNumber). \(badRow.message)")
                                    .font(.monospaced(.caption)())
                                    .foregroundColor(theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if viewModel.isImporting {
                ProgressView(value: viewModel.importProgress)
                    .frame(width: 160)
                Text("\(viewModel.importedRowCount) " + pluginLocalization.string("rows"))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if viewModel.isImporting {
                AppButton(pluginLocalization.string("Cancel"), style: .secondary, size: .small) {
                    viewModel.cancelImport()
                }
            } else if viewModel.importCompleted {
                AppButton(pluginLocalization.string("Done"), style: .primary, size: .small) {
                    isPresented = false
                }
            } else {
                AppButton(pluginLocalization.string("Cancel"), style: .secondary, size: .small) { isPresented = false }
                AppButton(pluginLocalization.string("Import"), systemImage: "square.and.arrow.down", style: .primary, size: .small) {
                    startImport()
                }
                .disabled(!canImport)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - Actions

    private func loadFile(_ url: URL) async {
        fileURL = url
        fileName = url.lastPathComponent
        await viewModel.loadImportPreview(url: url)
        guard viewModel.importError == nil else { return }
        targetTables = await viewModel.loadImportTargetTables()
        if targetTables.isEmpty, supportsNewTable {
            targetMode = .newTable
            targetColumns = viewModel.importSourceColumns
        } else {
            targetMode = .existingTable
            selectedTableID = targetTables.first?.id
            if let table = selectedTable {
                targetColumns = await viewModel.loadImportTargetColumns(table)
            } else {
                targetColumns = []
            }
        }
        rebuildMappings()
    }

    /// 源列变化（换文件/表头开关/目标切换）后重建映射：现有表按名对齐（大小写不敏感），新表同名映射。
    private func rebuildMappings() {
        let sources = viewModel.importSourceColumns
        let types = viewModel.importInferredTypes
        guard sources.count == types.count else {
            mappings = []
            return
        }
        let loweredTargets = targetColumns.map { $0.lowercased() }
        mappings = sources.enumerated().map { index, source in
            let target: String?
            if targetMode == .newTable {
                target = source
            } else {
                target = loweredTargets.firstIndex(of: source.lowercased()).map { targetColumns[$0] }
            }
            return ImportColumnMapping(sourceColumn: source, targetColumn: target, inferredType: types[index])
        }
    }

    private func startImport() {
        let target: ImportTarget
        switch targetMode {
        case .existingTable:
            guard let table = selectedTable else { return }
            target = .existingTable(table)
        case .newTable:
            let name = newTableName.trimmingCharacters(in: .whitespacesAndNewlines)
            target = .newTable(ImportMappingBuilder.newTableDraft(name: name, mappings: mappings))
        }
        viewModel.startImport(
            target: target,
            mappings: mappings,
            options: ImportOptions(emptyAsNull: emptyAsNull, badRowStrategy: badRowStrategy)
        )
    }
}