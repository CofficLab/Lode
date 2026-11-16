import SwiftUI
import LumiUI

/// 类型化单元格编辑器：按列类型路由到不同输入控件。
///
/// 所有编辑器共享一个文本缓冲 `text`，提交统一走 ``parseEditedCellValue``：
/// - 布尔/枚举：下拉选择，选中即写回文本并提交；
/// - 日期/日期时间/时间：字段式 DatePicker（UTC，保证与库内文本往返一致），
///   选择变化即写回格式化文本，回车或 ✓ 提交；
/// - JSON：文本输入 + 实时校验（非法时红框，回车不提交）；
/// - 整数/小数：字符过滤的文本输入；
/// - 文本/二进制：普通文本输入（二进制沿用 hex 表示）。
struct TypedCellEditor: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    let kind: CellEditorKind
    let width: CGFloat
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var dateValue: Date = Date()

    var body: some View {
        editor
            .frame(width: editorWidth, alignment: .leading)
            .onAppear {
                dateValue = parseCellDate(text, kind: kind) ?? Date()
                focused = true
            }
            .onKeyPress(.escape) {
                onCancel()
                return .handled
            }
    }

    /// 日期时间控件需要更宽的空间，避免字段被截断。
    private var editorWidth: CGFloat {
        switch kind {
        case .dateTime: return max(width, 216)
        case .date: return max(width, 140)
        case .time: return max(width, 120)
        default: return width
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch kind {
        case .boolean:
            booleanPicker
        case .enumeration(let values):
            enumPicker(values)
        case .date, .dateTime, .time:
            datePicker
        case .json:
            jsonField
        case .integer:
            numericField(allowed: "-+0123456789")
        case .decimal:
            numericField(allowed: "-+0123456789.eE")
        case .text, .binary:
            plainField
        }
    }

    // MARK: - 布尔

    private var booleanPicker: some View {
        Picker("", selection: Binding(
            get: { Self.isTruthy(text) ? "true" : "false" },
            set: { newValue in
                text = newValue
                onCommit()
            }
        )) {
            Text("true").tag("true")
            Text("false").tag("false")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .padding(4)
        .background(theme.warning.opacity(0.15))
        .border(theme.warning)
    }

    private static func isTruthy(_ text: String) -> Bool {
        ["true", "t", "yes", "y", "1"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: - 枚举

    private func enumPicker(_ values: [String]) -> some View {
        // 当前值不在合法取值内（如 NULL/历史脏值）时仍作为选项展示，避免空白。
        let options = values.contains(text) ? values : [text] + values
        return Picker("", selection: Binding(
            get: { text },
            set: { newValue in
                text = newValue
                onCommit()
            }
        )) {
            ForEach(options, id: \.self) { value in
                Text(value.isEmpty ? "⟨empty⟩" : value).tag(value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .padding(4)
        .background(theme.warning.opacity(0.15))
        .border(theme.warning)
    }

    // MARK: - 日期/时间

    private var dateComponents: DatePickerComponents {
        switch kind {
        case .date: return .date
        case .time: return .hourAndMinute
        default: return [.date, .hourAndMinute]
        }
    }

    private var datePicker: some View {
        HStack(spacing: 4) {
            DatePicker("", selection: $dateValue, displayedComponents: dateComponents)
                .datePickerStyle(.field)
                .labelsHidden()
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .onChange(of: dateValue) { _, newValue in
                    if let formatted = formatCellDate(newValue, kind: kind) {
                        text = formatted
                    }
                }
            Button(action: onCommit) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.success)
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(theme.warning.opacity(0.15))
        .border(theme.warning)
        .onKeyPress(.return) {
            onCommit()
            return .handled
        }
    }

    // MARK: - JSON

    private var jsonField: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = trimmed.isEmpty || isValidJSONText(text)
        return HStack(spacing: 4) {
            TextField("", text: $text)
                .font(.monospaced(.body)())
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { if valid { onCommit() } }
            Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(valid ? theme.success : theme.error)
        }
        .padding(8)
        .background(theme.warning.opacity(0.15))
        .border(valid ? theme.warning : theme.error)
    }

    // MARK: - 数字/文本

    private func numericField(allowed: String) -> some View {
        TextField("", text: $text)
            .font(.monospaced(.body)())
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onCommit() }
            .onChange(of: text) { _, newValue in
                let filtered = String(newValue.filter { allowed.contains($0) })
                if filtered != newValue { text = filtered }
            }
            .padding(8)
            .background(theme.warning.opacity(0.15))
            .border(theme.warning)
    }

    private var plainField: some View {
        TextField("", text: $text)
            .font(.monospaced(.body)())
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onCommit() }
            .padding(8)
            .background(theme.warning.opacity(0.15))
            .border(theme.warning)
    }
}