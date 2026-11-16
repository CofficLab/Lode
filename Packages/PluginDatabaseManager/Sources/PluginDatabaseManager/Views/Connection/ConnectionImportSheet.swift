import LumiUI
import SwiftUI
import UniformTypeIdentifiers

/// 连接导入面板：从本机已安装的其他数据库客户端配置文件还原连接。
///
/// 两步流程：
/// 1. 选择来源——列出本机检测到的客户端（默认配置文件存在），或为任一客户端手动选择文件；
/// 2. 预览勾选——展示解析出的连接（名称/引擎/主机），勾选后批量入库。
///
/// 安全：密码与 SSH 私钥存放在源客户端的钥匙串/加密字段中，不随导入搬运；
/// 面板明确提示用户导入后自行补填。重复连接（同名+同引擎+同主机+同库）自动跳过。
struct ConnectionImportSheet: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var isPresented: Bool

    @State private var availableSources: [ConnectionImportSource] = []
    @State private var parsed: [DatabaseConfig] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var activeSource: ConnectionImportSource?
    @State private var errorText: String?
    @State private var filePickerSource: ConnectionImportSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            AppDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorText {
                        AppErrorBanner(message: LocalizedStringKey(errorText))
                    }
                    if parsed.isEmpty {
                        sourceSelection
                    } else {
                        preview
                    }
                }
                .padding(16)
            }
            AppDivider()
            footer
        }
        .frame(width: 460, height: 520)
        .background(theme.surface)
        .onAppear { availableSources = ConnectionImporter.availableSources() }
        .fileImporter(
            isPresented: Binding(
                get: { filePickerSource != nil },
                set: { if !$0 { filePickerSource = nil } }
            ),
            allowedContentTypes: [.propertyList, .json]
        ) { result in
            handleFilePick(result)
        }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack {
            Text(pluginLocalization.string("Import Connections"))
                .font(.appTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Close"), size: .compact) {
                isPresented = false
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !parsed.isEmpty {
                AppButton(pluginLocalization.string("Back"), style: .ghost) {
                    parsed = []
                    selectedIDs = []
                    activeSource = nil
                    errorText = nil
                }
            }
            Spacer()
            if parsed.isEmpty {
                AppButton(pluginLocalization.string("Close"), style: .secondary) {
                    isPresented = false
                }
            } else {
                AppButton(
                    String(format: pluginLocalization.string("Import %d Connections"), selectedIDs.count),
                    systemImage: "square.and.arrow.down",
                    style: .primary
                ) {
                    performImport()
                }
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Step 1: source selection

    private var sourceSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if availableSources.isEmpty {
                AppEmptyState(
                    icon: "square.and.arrow.down",
                    title: pluginLocalization.string("No supported clients detected"),
                    description: pluginLocalization.string("Choose a configuration file to import.")
                )
            } else {
                Text(pluginLocalization.string("Detected on this Mac"))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
                VStack(spacing: 4) {
                    ForEach(availableSources) { source in
                        AppListRow(isSelected: false, action: { loadSource(source) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "app.badge")
                                    .foregroundStyle(theme.primary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(source.displayTitle)
                                        .font(.appBodyEmphasized)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(pluginLocalization.string("Import saved connections"))
                                        .font(.appCaption)
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.appCaption)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                }
            }

            Text(pluginLocalization.string("Choose a file"))
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
            VStack(spacing: 4) {
                ForEach(ConnectionImportSource.allCases) { source in
                    AppListRow(isSelected: false, action: { filePickerSource = source }) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(theme.textSecondary)
                            Text(source.displayTitle)
                                .font(.appBody)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text(pluginLocalization.string("Browse…"))
                                .font(.appCaption)
                                .foregroundStyle(theme.primary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step 2: preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(activeSource?.displayTitle ?? "")
                    .font(.appBodyEmphasized)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(String(format: pluginLocalization.string("%d connections found"), parsed.count))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
            }

            Toggle(isOn: Binding(
                get: { !parsed.isEmpty && selectedIDs.count == parsed.count },
                set: { selectedIDs = $0 ? Set(parsed.map(\.id)) : [] }
            )) {
                Text(pluginLocalization.string("Select All"))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
            }
            .toggleStyle(.checkbox)

            VStack(spacing: 4) {
                ForEach(parsed) { config in
                    AppListRow(isSelected: selectedIDs.contains(config.id), action: { toggle(config.id) }) {
                        HStack(spacing: 8) {
                            Image(systemName: selectedIDs.contains(config.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(config.id) ? theme.primary : theme.textTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(config.name)
                                    .font(.appMicroEmphasized)
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Text(detailLine(for: config))
                                    .font(.appCaption)
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
            }

            Text(pluginLocalization.string("Passwords and SSH keys are not imported. Re-enter them after import."))
                .font(.appCaption)
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func loadSource(_ source: ConnectionImportSource) {
        guard let url = ConnectionImporter.defaultURL(for: source) else { return }
        load(url: url, source: source)
    }

    private func load(url: URL, source: ConnectionImportSource) {
        do {
            let configs = try ConnectionImporter.importConnections(from: url, source: source)
            activeSource = source
            parsed = configs
            selectedIDs = Set(configs.map(\.id))
            errorText = configs.isEmpty ? pluginLocalization.string("No connections were found in this file.") : nil
        } catch {
            parsed = []
            selectedIDs = []
            errorText = error.localizedDescription
        }
    }

    private func handleFilePick(_ result: Result<URL, Error>) {
        guard let source = filePickerSource else { return }
        filePickerSource = nil
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            load(url: url, source: source)
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }

    private func performImport() {
        let chosen = parsed.filter { selectedIDs.contains($0.id) }
        viewModel.importConfigs(chosen)
        isPresented = false
    }

    private func detailLine(for config: DatabaseConfig) -> String {
        switch config.type {
        case .sqlite:
            return "SQLite · \(config.database)"
        case .redis:
            return "Redis · \(config.host ?? "127.0.0.1"):\(config.port ?? 6379)"
        case .mysql:
            return "MySQL · \(config.host ?? "127.0.0.1"):\(config.port ?? 3306)/\(config.database)"
        case .postgresql:
            return "PostgreSQL · \(config.host ?? "127.0.0.1"):\(config.port ?? 5432)/\(config.database)"
        }
    }
}