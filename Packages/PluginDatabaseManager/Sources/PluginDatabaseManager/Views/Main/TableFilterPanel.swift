import LumiUI
import SwiftUI

/// 表筛选面板：条件构建（列/运算符/操作数/启用/大小写）或 raw WHERE 高级模式，
/// 附带 WHERE 预览。挂在 ``TableDataView`` 结果区上方，可折叠。
struct TableFilterPanel: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel

    private var dialect: DatabaseType { viewModel.selectedConfig?.type ?? .sqlite }
    private var columnNames: [String] { viewModel.selectedTableSchema?.columns.map(\.name) ?? [] }
    private var availableOperators: [FilterOperator] {
        FilterOperator.allCases.filter { $0.isAvailable(for: dialect) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if viewModel.tableFilter.useRawWhere {
                rawWhereEditor
            } else {
                conditionList
            }
            if let preview = viewModel.filterPreviewSQL {
                Text(preview)
                    .font(.monospaced(.caption)())
                    .foregroundColor(theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.appSubtleBorder.opacity(0.4), in: .rect(cornerRadius: 6))
            }
            footer
        }
        .padding(12)
        .appSurface(style: .toolbar, cornerRadius: 0)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(theme.primary)
            Text(pluginLocalization.string("Filter"))
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
            Spacer()
            Picker("", selection: $viewModel.tableFilter.useRawWhere) {
                Text(pluginLocalization.string("Conditions")).tag(false)
                Text(pluginLocalization.string("Raw WHERE")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Close"), size: .compact) {
                viewModel.showFilterPanel = false
            }
        }
    }

    // MARK: - Conditions

    private var conditionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.tableFilter.conditions.isEmpty {
                Text(pluginLocalization.string("No filter conditions. Add one to narrow the rows."))
                    .font(.appCaption)
                    .foregroundColor(theme.textTertiary)
            }
            ForEach(Array(viewModel.tableFilter.conditions.enumerated()), id: \.element.id) { index, condition in
                conditionRow(index: index, condition: condition)
            }
            AppButton(pluginLocalization.string("Add Condition"), systemImage: "plus", style: .ghost, size: .small) {
                viewModel.addFilterCondition()
            }
        }
    }

    private func conditionRow(index: Int, condition: FilterCondition) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: enabledBinding(index))
                .labelsHidden()
                .toggleStyle(.checkbox)

            Picker("", selection: columnBinding(index)) {
                ForEach(columnNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)

            Picker("", selection: operatorBinding(index)) {
                ForEach(availableOperators) { op in
                    Text(op.displayTitle).tag(op)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)

            operandFields(index: index, condition: condition)

            if condition.op.isTextPattern {
                Toggle(pluginLocalization.string("Aa"), isOn: caseSensitiveBinding(index))
                    .toggleStyle(.button)
                    .help(pluginLocalization.string("Case sensitive"))
            }

            Spacer(minLength: 0)

            AppIconButton(systemImage: "trash", label: pluginLocalization.string("Remove"), size: .compact) {
                viewModel.removeFilterCondition(condition.id)
            }
        }
    }

    @ViewBuilder
    private func operandFields(index: Int, condition: FilterCondition) -> some View {
        switch condition.op.operandKind {
        case .none:
            EmptyView()
        case .single:
            operandField(operandBinding(index, 0), placeholder: pluginLocalization.string("Value"))
                .frame(width: 160)
        case .pair:
            operandField(operandBinding(index, 0), placeholder: pluginLocalization.string("From"))
                .frame(width: 110)
            Text(pluginLocalization.string("and"))
                .font(.appMicro)
                .foregroundColor(theme.textTertiary)
            operandField(operandBinding(index, 1), placeholder: pluginLocalization.string("To"))
                .frame(width: 110)
        case .list:
            operandField(listBinding(index), placeholder: pluginLocalization.string("Comma-separated values"))
                .frame(width: 220)
        }
    }

    private func operandField(_ binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(.appMicro)
            .foregroundColor(theme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(theme.appSubtleBorder.opacity(0.5), in: .rect(cornerRadius: 6))
    }

    // MARK: - Raw WHERE

    private var rawWhereEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pluginLocalization.string("Raw WHERE clause (without the WHERE keyword)"))
                .font(.appCaption)
                .foregroundColor(theme.textSecondary)
            TextField("age > 18 AND name LIKE 'a%'", text: $viewModel.tableFilter.rawWhere, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.monospaced(.caption)())
                .foregroundColor(theme.textPrimary)
                .lineLimit(2...4)
                .padding(8)
                .background(theme.appSubtleBorder.opacity(0.5), in: .rect(cornerRadius: 6))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            AppButton(pluginLocalization.string("Clear"), systemImage: "xmark.circle", style: .secondary, size: .small) {
                Task { await viewModel.clearFilter() }
            }
            .disabled(!viewModel.tableFilter.isActive)
            Spacer()
            AppButton(pluginLocalization.string("Apply Filter"), systemImage: "checkmark.circle.fill", style: .primary, size: .small) {
                Task { await viewModel.applyFilter() }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Bindings

    private func enabledBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { viewModel.tableFilter.conditions[index].isEnabled },
            set: { viewModel.tableFilter.conditions[index].isEnabled = $0 }
        )
    }

    private func columnBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { viewModel.tableFilter.conditions[index].column },
            set: { viewModel.tableFilter.conditions[index].column = $0 }
        )
    }

    private func operatorBinding(_ index: Int) -> Binding<FilterOperator> {
        Binding(
            get: { viewModel.tableFilter.conditions[index].op },
            set: { viewModel.tableFilter.conditions[index].op = $0 }
        )
    }

    private func caseSensitiveBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { viewModel.tableFilter.conditions[index].caseSensitive },
            set: { viewModel.tableFilter.conditions[index].caseSensitive = $0 }
        )
    }

    private func operandBinding(_ index: Int, _ operand: Int) -> Binding<String> {
        Binding(
            get: {
                let ops = viewModel.tableFilter.conditions[index].operands
                return operand < ops.count ? ops[operand] : ""
            },
            set: { newValue in
                var ops = viewModel.tableFilter.conditions[index].operands
                while ops.count <= operand { ops.append("") }
                ops[operand] = newValue
                viewModel.tableFilter.conditions[index].operands = ops
            }
        )
    }

    /// IN/NOT IN 列表以逗号分隔文本编辑，存回操作数数组。
    private func listBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { viewModel.tableFilter.conditions[index].operands.joined(separator: ", ") },
            set: { newValue in
                viewModel.tableFilter.conditions[index].operands =
                    newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        )
    }
}