import SwiftUI
import LumiUI

/// 侧边栏连接列表视图。
///
/// 复用 ``AppListRow`` 的行样式，
/// 行点击即 ``viewModel.connect(config:)``；连接成功后由调用方触发翻牌回到数据浏览。
///
/// 风格参考 `ConnectionPopoverView`，但作为侧边栏列表使用：
/// - 顶部 ``DatabaseSidebarHeaderBar``（标题 Connections + 加号 + 切换 + 更多菜单）；
///   「更多」菜单承载 Add Connection / Import Connections / Disconnect；
/// - 列表项展示图标、连接名、类型/host 副标题；当前连接显示绿色圆点；
/// - 右键上下文菜单提供「Edit / Delete」入口，Delete 需二次确认。
struct ConnectionsListView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    @ObservedObject var viewModel: DatabaseViewModel

    /// 点击切换按钮（数据/连接列表）的回调，由 ``SidebarView`` 传入。
    let onToggleMode: () -> Void

    /// Add Connection 表单是否展示。
    @State private var showAddConfigSheet: Bool = false
    /// 正在编辑的连接；非 nil 时弹出编辑表单。
    @State private var editingConfig: DatabaseConfig?
    /// 等待删除确认的连接。
    @State private var configPendingDeletion: DatabaseConfig?
    /// 连接导入面板是否展示。
    @State private var showImportSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            DatabaseSidebarHeaderBar(
                title: pluginLocalization.string("Connections"),
                systemImage: "cylinder.split.1x2",
                onAdd: { showAddConfigSheet = true },
                onToggleMode: onToggleMode,
                toggleMode: viewModel.sidebarMode,
                menuActions: [
                    DatabaseSidebarMenuAction(
                        title: "Add Connection",
                        systemImage: "plus",
                        action: { showAddConfigSheet = true }
                    ),
                    DatabaseSidebarMenuAction(
                        title: "Import Connections",
                        systemImage: "square.and.arrow.down",
                        action: { showImportSheet = true }
                    ),
                    DatabaseSidebarMenuAction(
                        title: "Disconnect",
                        systemImage: "power",
                        isEnabled: viewModel.isConnected,
                        action: { Task { await viewModel.disconnect() } }
                    ),
                ],
                usesAccentTint: true,
                accessibilityPrefix: "database.connections"
            )

            if viewModel.configs.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(connectionSections) { section in
                            if let title = section.title {
                                sectionHeader(title)
                            }
                            ForEach(section.configs, id: \.id) { config in
                                connectionRow(config)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAddConfigSheet) {
            ConnectionFormView(viewModel: viewModel, isPresented: $showAddConfigSheet)
        }
        .sheet(item: $editingConfig) { config in
            ConnectionFormView(viewModel: viewModel, isPresented: Binding(
                get: { editingConfig != nil },
                set: { if !$0 { editingConfig = nil } }
            ), editing: config)
        }
        .sheet(isPresented: $showImportSheet) {
            ConnectionImportSheet(viewModel: viewModel, isPresented: $showImportSheet)
        }
        .confirmationDialog(
            pluginLocalization.string("Delete this connection?"),
            isPresented: Binding(
                get: { configPendingDeletion != nil },
                set: { if !$0 { configPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pluginLocalization.string("Delete"), role: .destructive) {
                if let config = configPendingDeletion {
                    viewModel.removeConfig(config)
                }
                configPendingDeletion = nil
            }
            Button(pluginLocalization.string("Cancel"), role: .cancel) {
                configPendingDeletion = nil
            }
        } message: {
            if let config = configPendingDeletion {
                Text(pluginLocalization.string("The saved settings for “\(config.name)” will be removed. This cannot be undone."))
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            SidebarEmptyView(
                systemImage: "cylinder.split.1x2",
                title: pluginLocalization.string("No saved connections"),
                description: pluginLocalization.string("Click + to add a new connection.")
            )
            AppButton(
                pluginLocalization.string("Add Connection"),
                systemImage: "plus",
                style: .secondary,
                size: .small,
                action: { showAddConfigSheet = true }
            )
            .accessibilityIdentifier("database.connections.empty-add")
            .padding(.top, 4)
            AppButton(
                pluginLocalization.string("Import Connections"),
                systemImage: "square.and.arrow.down",
                style: .ghost,
                size: .small,
                action: { showImportSheet = true }
            )
            .accessibilityIdentifier("database.connections.empty-import")
        }
    }

    // MARK: - Row

    /// 侧边栏分区：未分组连接在前（无标题），命名分组按字母序在后，各带一个分区标题。
    private struct ConnectionSection: Identifiable {
        let id: String
        let title: String?
        let configs: [DatabaseConfig]
    }

    private var connectionSections: [ConnectionSection] {
        let ungrouped = viewModel.configs.filter { $0.group == nil }
        let grouped = Dictionary(grouping: viewModel.configs.filter { $0.group != nil }, by: { $0.group! })
        var sections: [ConnectionSection] = []
        if !ungrouped.isEmpty {
            sections.append(ConnectionSection(id: "\u{0}ungrouped", title: nil, configs: ungrouped))
        }
        for name in grouped.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            sections.append(ConnectionSection(id: name, title: name, configs: grouped[name] ?? []))
        }
        return sections
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.appMicroEmphasized)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// 颜色标签 → LumiUI 主题语义色（none 不显示圆点）。
    private func themeColor(for color: ConnectionColor) -> Color? {
        switch color {
        case .none: return nil
        case .blue: return theme.primary
        case .green: return theme.success
        case .orange: return theme.warning
        case .red: return theme.error
        case .purple: return theme.primarySecondary
        case .cyan: return theme.info
        }
    }

    private func connectionRow(_ config: DatabaseConfig) -> some View {
        let isSelected = viewModel.selectedConfig?.id == config.id
        let isConnected = isSelected && viewModel.isConnected

        return AppListRow(isSelected: isSelected, action: {
            Task { await viewModel.connect(config: config) }
        }) {
            HStack(spacing: 8) {
                if let dotColor = themeColor(for: config.connectionColor) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                        .help(pluginLocalization.string(config.connectionColor.displayTitle))
                }
                Image(systemName: icon(for: config.type))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name)
                        .font(.appMicroEmphasized)
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)
                    Text(detailLine(for: config))
                        .font(.appCaption)
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                safeModeTag(config.safeMode)
                statusIndicator(isSelected: isSelected, isConnected: isConnected)
            }
        }
        .accessibilityIdentifier("database.connections.row.\(config.name)")
        .contextMenu {
            Button {
                editingConfig = config
            } label: {
                Label(pluginLocalization.string("Edit"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                configPendingDeletion = config
            } label: {
                Label(pluginLocalization.string("Delete"), systemImage: "trash")
            }
        }
    }

    /// 安全模式彩色标签：readOnly 用 error 语义色、confirmWrites 用 warning 语义色，
    /// 提示生产/受保护连接。off 档不显示。沿用 ConflictResolutionSheet 徽章的视觉语言
    /// （AppTag 当前仅提供 subtle/accent 两档，无语义色变体，故按主题语义色自绘 chip）。
    @ViewBuilder
    private func safeModeTag(_ mode: ConnectionSafeMode) -> some View {
        switch mode {
        case .off:
            EmptyView()
        case .confirmWrites, .readOnly:
            let color = mode == .readOnly ? theme.error : theme.warning
            let icon = mode == .readOnly ? "lock.fill" : "exclamationmark.shield"
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(pluginLocalization.string(mode.displayTitle))
                    .font(.appMicro)
                    .lineLimit(1)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: .rect(cornerRadius: 6))
            .help(pluginLocalization.string(mode.helpText))
        }
    }

    @ViewBuilder
    private func statusIndicator(isSelected: Bool, isConnected: Bool) -> some View {
        if viewModel.isLoading && isSelected {
            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
        } else if isConnected {
            Circle().fill(theme.success).frame(width: 8, height: 8)
        } else if isSelected {
            Circle().stroke(theme.appSubtleBorder, lineWidth: 1).frame(width: 8, height: 8)
        }
    }

    private func icon(for type: DatabaseType) -> String {
        switch type {
        case .sqlite: return "doc.text.fill"
        case .mysql: return "cylinder.split.1x2.fill"
        case .postgresql: return "cylinder.split.1x2"
        case .redis: return "memorychip"
        }
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

#if DEBUG
#Preview("Connections") {
    ConnectionsListView(viewModel: DatabaseViewModel(), onToggleMode: {})
        .frame(width: 260, height: 360)
}
#endif