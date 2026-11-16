import AppKit
import LumiUI
import SwiftUI
import UniformTypeIdentifiers

/// 数据导出面板：选格式（CSV/JSON/SQL INSERT/Markdown）+ 行范围（当前页/全部/筛选）
/// + 预设管理 → 选保存路径 → 流式写盘（进度/停止）。执行走 ``DatabaseViewModel`` 导出管线。
struct ExportSheet: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var isPresented: Bool

    @State private var presetName = ""

    private var sourceName: String {
        viewModel.openTableObject?.name ?? pluginLocalization.string("Query result")
    }

    private var canExport: Bool {
        guard !viewModel.isExporting, !viewModel.exportCompleted else { return false }
        switch viewModel.exportRange {
        case .currentPage: return viewModel.queryResult != nil
        case .allRows, .filteredRows: return viewModel.openTableObject != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourceSection
                    formatSection
                    rangeSection
                    presetsSection
                    if viewModel.exportCompleted { completionSection }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let error = viewModel.exportError {
                AppErrorBanner(message: LocalizedStringKey(error))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            AppDivider()
            footer
        }
        .frame(width: 560, height: 520)
        .appSurface(style: .toolbar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(theme.primary)
            Text(pluginLocalization.string("Export Data"))
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
            Spacer()
            AppButton(pluginLocalization.string("Close"), style: .ghost, size: .small) {
                if viewModel.isExporting { viewModel.cancelExport() }
                isPresented = false
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var sourceSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells")
                .foregroundStyle(theme.textSecondary)
            Text(sourceName)
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            AppTag(viewModel.exportFormat.fileExtension.uppercased(), style: .subtle)
            Spacer()
        }
    }

    private var formatSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(pluginLocalization.string("Format"))
                    .font(.appMicroEmphasized)
                    .foregroundStyle(theme.textSecondary)
                Picker(pluginLocalization.string("Format"), selection: $viewModel.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(formatLabel(format)).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(viewModel.isExporting || viewModel.exportCompleted)
            }
        }
    }

    private var rangeSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(pluginLocalization.string("Rows"))
                    .font(.appMicroEmphasized)
                    .foregroundStyle(theme.textSecondary)
                Picker(pluginLocalization.string("Rows"), selection: $viewModel.exportRange) {
                    Text(pluginLocalization.string("Current Page")).tag(ExportRowRange.currentPage)
                    Text(pluginLocalization.string("All Rows")).tag(ExportRowRange.allRows)
                    Text(pluginLocalization.string("Filtered Rows")).tag(ExportRowRange.filteredRows)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(viewModel.isExporting || viewModel.exportCompleted)
            }
        }
    }

    private var presetsSection: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(pluginLocalization.string("Presets"))
                    .font(.appMicroEmphasized)
                    .foregroundStyle(theme.textSecondary)
                ForEach(viewModel.exportPresets) { preset in
                    HStack(spacing: 8) {
                        Button {
                            viewModel.applyExportPreset(preset)
                        } label: {
                            HStack(spacing: 6) {
                                Text(preset.name)
                                    .font(.appBody)
                                    .foregroundColor(theme.textPrimary)
                                    .lineLimit(1)
                                AppTag(formatLabel(preset.format), style: .subtle)
                                AppTag(rangeLabel(preset.range), style: .subtle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(pluginLocalization.string("Apply Preset"))
                        .disabled(viewModel.isExporting || viewModel.exportCompleted)
                        Spacer()
                        AppIconButton(systemImage: "trash", label: pluginLocalization.string("Delete Preset"), size: .compact) {
                            viewModel.deleteExportPreset(id: preset.id)
                        }
                        .disabled(viewModel.isExporting || viewModel.exportCompleted)
                    }
                    AppDivider()
                }
                HStack(spacing: 8) {
                    GlassTextField(title: pluginLocalization.string("Preset Name"), text: $presetName, placeholder: pluginLocalization.string("My preset"))
                    AppButton(pluginLocalization.string("Save Preset"), style: .secondary, size: .small) {
                        viewModel.saveExportPreset(name: presetName)
                        presetName = ""
                    }
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isExporting)
                }
            }
        }
    }

    private var completionSection: some View {
        AppCard {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                Text(pluginLocalization.string("Export complete."))
                    .font(.appBodyEmphasized)
                    .foregroundColor(theme.textPrimary)
                Text("\(viewModel.exportedRowCount) " + pluginLocalization.string("rows"))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if viewModel.isExporting {
                ProgressView(value: viewModel.exportProgress)
                    .frame(width: 160)
                Text("\(viewModel.exportedRowCount) " + pluginLocalization.string("rows"))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if viewModel.isExporting {
                AppButton(pluginLocalization.string("Stop"), style: .secondary, size: .small) {
                    viewModel.cancelExport()
                }
            } else if viewModel.exportCompleted {
                AppButton(pluginLocalization.string("Done"), style: .primary, size: .small) {
                    isPresented = false
                }
            } else {
                AppButton(pluginLocalization.string("Cancel"), style: .secondary, size: .small) { isPresented = false }
                AppButton(pluginLocalization.string("Export"), systemImage: "square.and.arrow.up", style: .primary, size: .small) {
                    chooseAndExport()
                }
                .disabled(!canExport)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - Helpers

    private func formatLabel(_ format: ExportFormat) -> String {
        switch format {
        case .csv: return pluginLocalization.string("CSV")
        case .json: return pluginLocalization.string("JSON")
        case .sqlInsert: return pluginLocalization.string("SQL INSERT")
        case .markdown: return pluginLocalization.string("Markdown")
        }
    }

    private func rangeLabel(_ range: ExportRowRange) -> String {
        switch range {
        case .currentPage: return pluginLocalization.string("Current Page")
        case .allRows: return pluginLocalization.string("All Rows")
        case .filteredRows: return pluginLocalization.string("Filtered Rows")
        }
    }

    private func chooseAndExport() {
        let panel = NSSavePanel()
        let ext = viewModel.exportFormat.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = "\(viewModel.openTableObject?.name ?? "query_result").\(ext)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.startExport(to: url)
        }
    }
}