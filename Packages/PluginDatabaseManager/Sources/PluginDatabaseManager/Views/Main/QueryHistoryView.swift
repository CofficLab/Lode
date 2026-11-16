import SwiftUI
import LumiUI

/// 查询历史面板：搜索 + 列表 + 点击载入编辑器。
///
/// 通过 ``DatabaseViewModel/showHistory`` 控制显示。
struct QueryHistoryView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel
    @State private var confirmClearAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            if viewModel.history.isEmpty {
                AppEmptyState(
                    icon: "clock.arrow.circlepath",
                    title: pluginLocalization.string("No history"),
                    description: pluginLocalization.string("Executed queries will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.history) { entry in
                            HistoryRow(entry: entry) {
                                viewModel.loadHistoryEntry(entry)
                            } onReRun: {
                                Task { await viewModel.reRunHistoryEntry(entry) }
                            } onTogglePin: {
                                Task { await viewModel.togglePinHistoryEntry(entry) }
                            } onDelete: {
                                Task { await viewModel.deleteHistoryEntry(entry) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 520)
        .onAppear { Task { await viewModel.loadRecentHistory() } }
        .confirmationDialog(
            pluginLocalization.string("Clear all query history?"),
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button(pluginLocalization.string("Clear All"), role: .destructive) {
                Task { await viewModel.clearHistory() }
            }
            Button(pluginLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(pluginLocalization.string("All recorded queries will be removed. This cannot be undone."))
        }
    }

    private var header: some View {
        HStack {
            Text(pluginLocalization.string("Query History"))
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
            Spacer()
            AppButton(pluginLocalization.string("Close"), style: .ghost, size: .small) {
                viewModel.showHistory = false
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(pluginLocalization.string("Search history"), text: $viewModel.historySearchText)
                .textFieldStyle(.plain)
                .font(.appCaption)
            if !viewModel.historySearchText.isEmpty {
                Button {
                    viewModel.historySearchText = ""
                    Task { await viewModel.loadRecentHistory() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(theme.appSubtleBorder, in: .rect(cornerRadius: 6))
        .onChange(of: viewModel.historySearchText) { new in
            Task { await viewModel.searchHistory(new) }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(viewModel.history.count) \(pluginLocalization.string("entries"))")
                .font(.appMicro)
                .foregroundStyle(.secondary)
            Spacer()
            retentionMenu
            AppButton(pluginLocalization.string("Clear All"), systemImage: "trash", style: .secondary, size: .small) {
                confirmClearAll = true
            }
            .disabled(viewModel.history.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var retentionMenu: some View {
        Menu {
            Button(pluginLocalization.string("Keep forever")) {
                Task { await viewModel.setHistoryRetentionDays(0) }
            }
            Button(pluginLocalization.string("7 days")) {
                Task { await viewModel.setHistoryRetentionDays(7) }
            }
            Button(pluginLocalization.string("30 days")) {
                Task { await viewModel.setHistoryRetentionDays(30) }
            }
            Button(pluginLocalization.string("90 days")) {
                Task { await viewModel.setHistoryRetentionDays(90) }
            }
        } label: {
            Label(retentionLabel, systemImage: "clock")
                .font(.appMicro)
                .foregroundStyle(theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(pluginLocalization.string("Retention"))
    }

    private var retentionLabel: String {
        switch viewModel.historyRetentionDays {
        case 0: return pluginLocalization.string("Keep forever")
        case 7: return pluginLocalization.string("7 days")
        case 30: return pluginLocalization.string("30 days")
        case 90: return pluginLocalization.string("90 days")
        default: return "\(viewModel.historyRetentionDays)d"
        }
    }
}

// MARK: - Row

private struct HistoryRow: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    let entry: QueryHistoryEntry
    var onLoad: () -> Void
    var onReRun: () -> Void
    var onTogglePin: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button(action: onLoad) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.sql)
                    .font(.monospaced(.callout)())
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if entry.pinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(theme.primary)
                            .accessibilityLabel(pluginLocalization.string("Pin"))
                    }
                    Label(entry.configName, systemImage: "cylinder.split.1x2")
                    Text("·")
                    Text(entry.database)
                    Spacer()
                    Text(relativeTime(entry.executedAt))
                }
                .font(.appMicro)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onReRun() } label: {
                Label(pluginLocalization.string("Re-run"), systemImage: "play.fill")
            }
            Button(pluginLocalization.string("Load into Editor")) { onLoad() }
            Button { onTogglePin() } label: {
                Label(
                    pluginLocalization.string(entry.pinned ? "Unpin" : "Pin"),
                    systemImage: entry.pinned ? "pin.slash" : "pin"
                )
            }
            Button(role: .destructive) { onDelete() } label: {
                Label(pluginLocalization.string("Delete"), systemImage: "trash")
            }
        }
        Divider()
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return pluginLocalization.string("just now") }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}
