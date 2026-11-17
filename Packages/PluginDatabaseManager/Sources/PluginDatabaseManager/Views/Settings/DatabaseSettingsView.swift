import LumiUI
import SwiftUI

/// 数据库插件设置面板（注入 App 设置窗口的右侧详情）。
///
/// 全部控件直接绑定 ``DatabaseViewModel/settings`` 与既有偏好状态，改动即时持久化。
/// 使用 LumiUI 的 ``AppSettingsSection``/``AppSettingsToggleRow``/``AppSettingsPickerRow``/
/// ``AppSettingsStepperRow`` 行组件，保证与宿主设置界面一致的观感。
struct DatabaseSettingsView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                querySection
                connectionSection
                editorSection
                historySection
                diagnosticsSection
                shortcutsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Query

    private var querySection: some View {
        AppSettingsSection(title: pluginLocalization.string("Query")) {
            AppSettingsPickerRow(
                pluginLocalization.string("Default row limit"),
                description: pluginLocalization.string("Maximum rows returned per query. Engine Default uses each database's own limit."),
                systemImage: "number",
                selection: $viewModel.settings.defaultQueryRowLimit
            ) {
                Picker("", selection: $viewModel.settings.defaultQueryRowLimit) {
                    ForEach(rowLimitOptions, id: \.self) { value in
                        Text(value == 0 ? pluginLocalization.string("Engine Default") : "\(value)").tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            AppSettingsToggleRow(
                pluginLocalization.string("Keyset pagination"),
                description: pluginLocalization.string("Use cursor-based paging for deep tables instead of OFFSET."),
                systemImage: "arrow.right.to.line",
                isOn: $viewModel.useKeysetPagination
            )
            AppSettingsToggleRow(
                pluginLocalization.string("Show NULL symbol"),
                description: pluginLocalization.string("Display NULL cells as ⟨NULL⟩ to distinguish them from empty text."),
                systemImage: "circle.slash",
                isOn: $viewModel.useNullSymbol
            )
        }
    }

    private var rowLimitOptions: [Int] {
        var presets = [0, 100, 200, 500, 1000, 2000, 5000, 10000]
        let current = viewModel.settings.defaultQueryRowLimit
        if !presets.contains(current) { presets.append(current) }
        return presets.sorted()
    }

    // MARK: - Connection

    private var connectionSection: some View {
        AppSettingsSection(title: pluginLocalization.string("Connections")) {
            AppSettingsPickerRow(
                pluginLocalization.string("Default safe mode"),
                description: pluginLocalization.string("Applied to newly created connections. Existing connections keep their own setting."),
                systemImage: "lock.shield",
                selection: $viewModel.settings.defaultSafeMode
            ) {
                Picker("", selection: $viewModel.settings.defaultSafeMode) {
                    ForEach(ConnectionSafeMode.allCases, id: \.rawValue) { mode in
                        Text(pluginLocalization.string(mode.displayTitle)).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    // MARK: - Editor

    private var editorSection: some View {
        AppSettingsSection(title: pluginLocalization.string("SQL Editor")) {
            AppSettingsPickerRow(
                pluginLocalization.string("Font size"),
                description: pluginLocalization.string("Editor text size. System Default follows the app font."),
                systemImage: "textformat.size",
                selection: $viewModel.settings.editorFontSize
            ) {
                Picker("", selection: $viewModel.settings.editorFontSize) {
                    ForEach(fontSizeOptions, id: \.self) { value in
                        Text(value == 0 ? pluginLocalization.string("System Default") : "\(Int(value)) pt").tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            AppSettingsPickerRow(
                pluginLocalization.string("Keyword case"),
                description: pluginLocalization.string("How the formatter renders SQL keywords."),
                systemImage: "textformat",
                selection: $viewModel.settings.keywordCase
            ) {
                Picker("", selection: $viewModel.settings.keywordCase) {
                    Text(pluginLocalization.string("UPPERCASE")).tag("upper")
                    Text(pluginLocalization.string("lowercase")).tag("lower")
                    Text(pluginLocalization.string("Preserve")).tag("preserve")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            AppSettingsStepperRow(
                pluginLocalization.string("Indent width"),
                description: pluginLocalization.string("Spaces per indentation level used by the formatter."),
                systemImage: "increase.indent",
                value: $viewModel.settings.indentWidth,
                in: 1...8
            )
            AppSettingsToggleRow(
                pluginLocalization.string("Indent with tabs"),
                description: pluginLocalization.string("Use tab characters instead of spaces when formatting."),
                systemImage: "arrow.right.to.line.compact",
                isOn: $viewModel.settings.useTabs
            )
            AppSettingsToggleRow(
                pluginLocalization.string("Clause per line"),
                description: pluginLocalization.string("Put each major SQL clause on its own line."),
                systemImage: "text.append",
                isOn: $viewModel.settings.clausePerLine
            )
            AppSettingsToggleRow(
                pluginLocalization.string("Comma newline in lists"),
                description: pluginLocalization.string("Break SELECT / GROUP BY / ORDER BY lists onto separate lines."),
                systemImage: "list.bullet",
                isOn: $viewModel.settings.commaNewlineInList
            )
        }
    }

    private var fontSizeOptions: [Double] {
        var presets: [Double] = [0, 11, 12, 13, 14, 15, 16, 18, 20]
        let current = viewModel.settings.editorFontSize
        if !presets.contains(current) { presets.append(current) }
        return presets.sorted()
    }

    // MARK: - History

    private var historySection: some View {
        AppSettingsSection(title: pluginLocalization.string("Query History")) {
            AppSettingsPickerRow(
                pluginLocalization.string("Retention"),
                description: pluginLocalization.string("How long executed queries are kept before automatic cleanup."),
                systemImage: "clock",
                selection: retentionBinding
            ) {
                Picker("", selection: retentionBinding) {
                    Text(pluginLocalization.string("Keep forever")).tag(0)
                    Text(pluginLocalization.string("7 days")).tag(7)
                    Text(pluginLocalization.string("30 days")).tag(30)
                    Text(pluginLocalization.string("90 days")).tag(90)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { viewModel.historyRetentionDays },
            set: { newValue in Task { await viewModel.setHistoryRetentionDays(newValue) } }
        )
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        AppSettingsSection(title: pluginLocalization.string("Diagnostics")) {
            AppSettingsToggleRow(
                pluginLocalization.string("Debug logging"),
                description: pluginLocalization.string("Record detailed diagnostic logs for troubleshooting. Credentials and passwords are always redacted before writing."),
                systemImage: "ladybug",
                isOn: $viewModel.settings.debugLoggingEnabled
            )
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        AppSettingsSection(
            title: pluginLocalization.string("Keyboard Shortcuts"),
            subtitle: pluginLocalization.string("Shortcuts available while the database workspace is active.")
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.shortcuts.enumerated()), id: \.offset) { index, shortcut in
                    if index > 0 { AppDivider() }
                    HStack {
                        Text(pluginLocalization.string(shortcut.title))
                            .font(.appCaption)
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text(shortcut.keys)
                            .font(.monospaced(.caption)())
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    /// 当前工作区已实现的快捷键参考（与工具栏/网格命令保持一致）。
    private static let shortcuts: [(title: String, keys: String)] = [
        ("Run statement at cursor", "⌘↩"),
        ("Run All", "⌘⇧↩"),
        ("Stop", "⌘."),
        ("Format", "⌘⇧F"),
        ("History", "⌘Y"),
        ("New Query Tab", "⌘T"),
        ("Close Tab", "⌘W"),
        ("Reopen Closed Tab", "⌘⇧T"),
        ("Next Tab", "⌃Tab"),
        ("Previous Tab", "⌃⇧Tab"),
        ("Select Tab 1…9", "⌘1…⌘9"),
        ("Find in grid", "⌘F"),
        ("Copy rows", "⌘⇧C"),
        ("Paste rows", "⌘⇧V"),
        ("Open SQL file", "⌘O"),
        ("Save SQL file", "⌘S"),
        ("Save SQL file as", "⌘⇧S"),
        ("Commit changes", "⌘S"),
        ("New row", "⌘⇧N"),
    ]
}