import SwiftUI
import LumiUI

/// Database Sidebar 顶部标题栏。
///
/// 左侧显示当前内容对应的图标和标题（Tables / Keys / Connections），
/// 右侧按钮区域包含：
/// - `onLoad`（可选）：数据列表的 Reload 按钮；
/// - `onAdd`（可选）：连接列表的「添加连接」按钮；
/// - `onToggleMode`（可选）：数据/连接列表切换按钮（卡片翻转）；
/// - `menuActions`（可选）：最右侧「更多」按钮弹出的菜单项。
///
/// 样式与 `ConversationListPlugin.ListView` 的 `headerBar` 保持一致:
/// secondary 图标 + caption 标题；默认 secondary 0.06 背景，`usesAccentTint`
/// 时改为主题色导航层着色。
/// `padding(.horizontal, 10)` / `padding(.vertical, 6)`。
struct DatabaseSidebarHeaderBar: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    // MARK: - Properties

    /// 显示的标题（"Tables" / "Keys" / "Connections"）。
    let title: String

    /// 标题左侧的系统图标。
    let systemImage: String

    /// 点击 Reload 按钮触发的回调。传 nil 时不显示。
    var onLoad: (() -> Void)? = nil

    /// 点击「添加连接」触发的回调。传 nil 时不显示。
    var onAdd: (() -> Void)? = nil

    /// 点击切换数据/连接列表触发的回调。传 nil 时不显示。
    var onToggleMode: (() -> Void)? = nil

    /// 切换按钮在哪种模式下点击。决定按钮的提示文本和图标朝向。
    /// nil 时使用通用「切换」图标。
    var toggleMode: DatabaseSidebarMode? = nil

    /// 「更多」按钮的菜单项。为空时不显示该按钮。
    var menuActions: [DatabaseSidebarMenuAction] = []

    /// 是否使用主题色导航层着色。连接列表（入口层）开启后头部铺 `primary` 10%，
    /// 与数据浏览层的中性灰头部拉开层级；正文层由调用方叠同色淡染。
    var usesAccentTint: Bool = false

    /// 可选的无障碍标识前缀，供 UI 测试稳定定位标题栏按钮。
    var accessibilityPrefix: String? = nil

    // MARK: - Initialization

    init(
        title: String,
        systemImage: String,
        onLoad: (() -> Void)? = nil,
        onAdd: (() -> Void)? = nil,
        onToggleMode: (() -> Void)? = nil,
        toggleMode: DatabaseSidebarMode? = nil,
        menuActions: [DatabaseSidebarMenuAction] = [],
        usesAccentTint: Bool = false,
        accessibilityPrefix: String? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.onLoad = onLoad
        self.onAdd = onAdd
        self.onToggleMode = onToggleMode
        self.toggleMode = toggleMode
        self.menuActions = menuActions
        self.usesAccentTint = usesAccentTint
        self.accessibilityPrefix = accessibilityPrefix
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if let onLoad {
                AppIconButton(systemImage: "arrow.clockwise", action: onLoad)
                    .help(pluginLocalization.string("Reload"))
                    .accessibilityIdentifier(identifier("reload"))
            }

            if let onAdd {
                AppIconButton(systemImage: "plus", action: onAdd)
                    .help(pluginLocalization.string("Add Connection"))
                    .accessibilityIdentifier(identifier("add"))
            }

            if let onToggleMode {
                AppIconButton(systemImage: toggleIconName, action: onToggleMode)
                    .help(toggleHelpText)
                    .accessibilityIdentifier(identifier("toggle"))
            }

            if !menuActions.isEmpty {
                AppIconMenuButton(
                    systemImage: "ellipsis",
                    label: pluginLocalization.string("More"),
                    accessibilityIdentifier: identifier("more")
                ) {
                    ForEach(Array(menuActions.enumerated()), id: \.offset) { index, item in
                        Button {
                            item.action()
                        } label: {
                            Label(pluginLocalization.string(item.title), systemImage: item.systemImage)
                        }
                        .disabled(!item.isEnabled)
                        .accessibilityIdentifier(identifier("menu.\(index)"))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(usesAccentTint ? theme.primary.opacity(0.10) : Color.secondary.opacity(0.06))
    }

    private func identifier(_ suffix: String) -> String {
        accessibilityPrefix.map { "\($0).\(suffix)" } ?? "database.header.\(suffix)"
    }

    private var toggleIconName: String {
        // 同一图标随模式自旋 90°，暗示「卡片翻转」
        "rectangle.portrait.on.rectangle.portrait"
    }

    private var toggleHelpText: String {
        switch toggleMode {
        case .connections:
            return pluginLocalization.string("Show Tables")
        case .browser:
            return pluginLocalization.string("Show Connections")
        case .none:
            return pluginLocalization.string("Toggle")
        }
    }
}

/// 顶部「更多」菜单中的一项操作。
struct DatabaseSidebarMenuAction {
    let title: String
    let systemImage: String
    var isEnabled: Bool = true
    let action: () -> Void
}

/// 侧边栏内容模式：数据浏览（Tables/Keys）或连接列表。
///
/// 由 ``DatabaseViewModel.sidebarMode`` 持有，两种模式共用同一份
/// 连接配置、但展示不同的子视图，通过 ``SidebarView`` 的 3D 翻转动画切换。
public enum DatabaseSidebarMode: String, Hashable {
    case browser
    case connections
}

#if DEBUG
#Preview("Tables") {
    DatabaseSidebarHeaderBar(title: pluginLocalization.string("Tables"), systemImage: "tablecells", onLoad: {}, onToggleMode: {}, toggleMode: .browser)
        .frame(width: 260)
}

#Preview("Connections") {
    DatabaseSidebarHeaderBar(
        title: pluginLocalization.string("Connections"),
        systemImage: "cylinder.split.1x2",
        onAdd: {},
        onToggleMode: {},
        toggleMode: .connections,
        menuActions: [
            DatabaseSidebarMenuAction(title: "Add Connection", systemImage: "plus", action: {}),
            DatabaseSidebarMenuAction(title: "Import Connections", systemImage: "square.and.arrow.down", action: {}),
            DatabaseSidebarMenuAction(title: "Disconnect", systemImage: "power", isEnabled: false, action: {}),
        ]
    )
    .frame(width: 260)
}
#endif
