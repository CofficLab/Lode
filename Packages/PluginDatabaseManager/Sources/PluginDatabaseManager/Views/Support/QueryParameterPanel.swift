import LumiUI
import SwiftUI

/// 命名参数面板：为编辑器文本中的 `:name` 占位符录入类型化绑定值。
///
/// 挂在查询编辑器下方，仅当存在命名参数时显示。每行：参数名 / 类型 / 值 / NULL 开关。
/// 缺值或类型非法在执行前拦截（见 ``DatabaseViewModel/resolveParameters(_:type:)``）。
struct QueryParameterPanel: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(viewModel.activeParameterNames, id: \.self) { name in
                parameterRow(name)
            }
        }
        .padding(12)
        .appSurface(style: .toolbar, cornerRadius: 0)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "curlybraces")
                .foregroundStyle(theme.primary)
            Text(pluginLocalization.string("Parameters"))
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
            Text("\(viewModel.activeParameterNames.count)")
                .font(.appMicro)
                .foregroundColor(theme.textTertiary)
            Spacer()
        }
    }

    private func parameterRow(_ name: String) -> some View {
        let isNull = viewModel.parameterBindings[name]?.isNull ?? false
        return HStack(spacing: 6) {
            Text(":\(name)")
                .font(.monospaced(.caption)())
                .foregroundColor(theme.textSecondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)

            Picker("", selection: kindBinding(name)) {
                ForEach(QueryParameterBinding.Kind.allCases) { kind in
                    Text(kindTitle(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)

            AppInputField(
                localizedPlaceholder: pluginLocalization.string("Value"),
                text: textBinding(name),
                size: .compact
            )
            .disabled(isNull)
            .opacity(isNull ? 0.4 : 1)
            .frame(maxWidth: .infinity)

            Toggle(pluginLocalization.string("NULL"), isOn: nullBinding(name))
                .toggleStyle(.checkbox)
                .font(.appMicro)
                .help(pluginLocalization.string("Bind SQL NULL"))
        }
    }

    private func kindTitle(_ kind: QueryParameterBinding.Kind) -> String {
        switch kind {
        case .text: return pluginLocalization.string("Text")
        case .integer: return pluginLocalization.string("Integer")
        case .real: return pluginLocalization.string("Real")
        case .boolean: return pluginLocalization.string("Boolean")
        }
    }

    // MARK: - Bindings

    private func kindBinding(_ name: String) -> Binding<QueryParameterBinding.Kind> {
        Binding(
            get: { viewModel.parameterBindings[name]?.kind ?? .text },
            set: { viewModel.parameterBindings[name, default: QueryParameterBinding()].kind = $0 }
        )
    }

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { viewModel.parameterBindings[name]?.text ?? "" },
            set: { viewModel.parameterBindings[name, default: QueryParameterBinding()].text = $0 }
        )
    }

    private func nullBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.parameterBindings[name]?.isNull ?? false },
            set: { viewModel.parameterBindings[name, default: QueryParameterBinding()].isNull = $0 }
        )
    }
}