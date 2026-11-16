import LumiUI
import SwiftUI

/// 只读 EXPLAIN 计划面板：把当前查询的执行计划渲染成可折叠树，
/// 高亮瓶颈节点（实际时间/代价/行数最大者）。PG 可切换 ANALYZE（真实执行，走安全闸门）。
/// 解析失败时原样展示 rawText，绝不丢信息。
struct QueryPlanView: View {
    @LumiTheme private var theme: any LumiUITheme

    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var isPresented: Bool

    @State private var expanded: Set<String> = []
    @State private var analyze: Bool = false

    private var isPostgreSQL: Bool { viewModel.selectedConfig?.type == .postgresql }

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            if let plan = viewModel.queryPlan, !plan.isEmpty {
                summaryBar(plan)
                AppDivider()
            }
            content
        }
        .frame(width: 880, height: 640)
        .background(theme.surface)
        .onAppear { seedExpanded() }
        .onChange(of: planSignature) { _, _ in seedExpanded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(pluginLocalization.string("Query Plan"))
                .font(.appTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if isPostgreSQL {
                Toggle(pluginLocalization.string("Analyze"), isOn: $analyze)
                    .toggleStyle(.checkbox)
                    .font(.appCaption)
                    .help(pluginLocalization.string("EXPLAIN ANALYZE actually executes the query."))
            }
            if viewModel.queryPlan?.isEmpty == false {
                AppIconButton(systemImage: "arrow.down.right.and.arrow.up.left", label: pluginLocalization.string("Expand All"), size: .compact) {
                    expanded = Set(viewModel.queryPlan?.allNodes().map(\.id) ?? [])
                }
                AppIconButton(systemImage: "arrow.up.left.and.arrow.down.right", label: pluginLocalization.string("Collapse All"), size: .compact) {
                    expanded = []
                }
            }
            AppIconButton(systemImage: "arrow.clockwise", label: pluginLocalization.string("Re-run"), size: .compact) {
                Task { await viewModel.explainCurrentQuery(analyze: analyze) }
            }
            .disabled(viewModel.isLoadingPlan)
            AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Close"), size: .compact) {
                isPresented = false
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func summaryBar(_ plan: QueryPlan) -> some View {
        HStack(spacing: 12) {
            if plan.analyze {
                AppTag("ANALYZE", systemImage: "stopwatch", style: .accent)
            }
            if let planning = plan.planningTimeMs {
                metric(pluginLocalization.string("Planning Time"), formatMs(planning))
            }
            if let execution = plan.executionTimeMs {
                metric(pluginLocalization.string("Execution Time"), formatMs(execution))
            }
            if let bottleneck = plan.allNodes().first(where: { $0.id == plan.bottleneckNodeID }) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(pluginLocalization.string("Bottleneck") + ": " + bottleneck.operation)
                        .lineLimit(1)
                }
                .font(.appCaption)
                .foregroundStyle(theme.warning)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(theme.textTertiary)
            Text(value).foregroundStyle(theme.textSecondary)
        }
        .font(.appCaption)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.queryPlanError {
            VStack(spacing: 12) {
                AppErrorBanner(message: LocalizedStringKey(error))
                AppButton(pluginLocalization.string("Retry"), style: .secondary) {
                    Task { await viewModel.explainCurrentQuery(analyze: analyze) }
                }
            }
            .padding(16)
        }
        if viewModel.isLoadingPlan && viewModel.queryPlan == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan = viewModel.queryPlan, !plan.roots.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.roots) { node in
                        PlanNodeView(node: node, plan: plan, expanded: $expanded)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let raw = viewModel.queryPlan?.rawText, !raw.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(pluginLocalization.string("The plan could not be parsed; showing raw output."))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
                ScrollView {
                    Text(raw)
                        .font(.appBody.monospaced())
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        } else if !viewModel.isLoadingPlan {
            AppEmptyState(
                icon: "list.bullet.indent",
                title: pluginLocalization.string("No query plan"),
                description: pluginLocalization.string("Write a query, then run Explain to visualize its execution plan.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private var planSignature: String {
        viewModel.queryPlan?.allNodes().map(\.id).joined(separator: "|") ?? ""
    }

    private func seedExpanded() {
        expanded = Set(viewModel.queryPlan?.allNodes().map(\.id) ?? [])
    }
}

/// 计划树的一个节点行 + 其子树。瓶颈节点用 warning 底色/边框高亮。
/// SQLite 的 operation 已是完整 detail，relation/index/filter/details 均为其子串，
/// 故仅对 PG/MySQL 渲染补充字段，避免重复。
private struct PlanNodeView: View {
    @LumiTheme private var theme: any LumiUITheme

    let node: QueryPlanNode
    let plan: QueryPlan
    @Binding var expanded: Set<String>

    private var isExpanded: Bool { expanded.contains(node.id) }
    private var isBottleneck: Bool { plan.bottleneckNodeID == node.id }
    private var showDetails: Bool { plan.engine != .sqlite }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if isExpanded && !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(node.children) { child in
                        PlanNodeView(node: child, plan: plan, expanded: $expanded)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 6) {
            if node.children.isEmpty {
                Color.clear.frame(width: 12, height: 14)
            } else {
                Button {
                    if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.operation)
                        .font(.appBodyEmphasized)
                        .foregroundStyle(theme.textPrimary)
                    if isBottleneck {
                        Text(pluginLocalization.string("Bottleneck"))
                            .font(.appMicroEmphasized)
                            .foregroundStyle(theme.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.warning.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if showDetails, let relation = node.relation {
                        Text(relation)
                            .font(.appCaption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                if showDetails {
                    supplementary
                }
                metrics
                if showDetails, let filter = node.filter {
                    Text(pluginLocalization.string("Filter") + ": " + filter)
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                }
                if showDetails {
                    ForEach(node.details, id: \.self) { detail in
                        Text(detail)
                            .font(.appMicro)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(isBottleneck ? theme.warning.opacity(0.10) : theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isBottleneck ? theme.warning.opacity(0.5) : theme.appSubtleBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var supplementary: some View {
        if let index = node.index {
            Text(pluginLocalization.string("Index") + ": " + index)
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
        }
        if let alias = node.alias, alias != node.relation {
            Text(alias)
                .font(.appMicro)
                .foregroundStyle(theme.textTertiary)
        }
    }

    @ViewBuilder
    private var metrics: some View {
        let chips = metricChips
        if !chips.isEmpty {
            HStack(spacing: 10) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip)
                        .font(.appMicro)
                        .foregroundStyle(theme.textSecondary)
                }
                if let time = node.actualTotalTimeMs {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(formatMs(time) + (node.actualLoops ?? 1 > 1 ? " ×\(node.actualLoops!)" : ""))
                            .font(.appMicro)
                    }
                    .foregroundStyle(theme.info)
                }
            }
        }
    }

    private var metricChips: [String] {
        var chips: [String] = []
        if let cost = node.estimatedTotalCost {
            chips.append(pluginLocalization.string("Cost") + " " + formatCost(cost))
        }
        if let estimated = node.estimatedRows {
            var text = pluginLocalization.string("Rows") + " " + formatNumber(estimated)
            if let actual = node.actualRows {
                text += " → " + formatNumber(actual)
            }
            chips.append(text)
        } else if let actual = node.actualRows {
            chips.append(pluginLocalization.string("Rows") + " " + formatNumber(actual))
        }
        return chips
    }
}

// MARK: - 数值格式化

private func formatMs(_ value: Double) -> String {
    String(format: "%.2f ms", value)
}

private func formatCost(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func formatNumber(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
}