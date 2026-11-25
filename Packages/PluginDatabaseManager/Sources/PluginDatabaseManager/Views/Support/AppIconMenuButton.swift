import SwiftUI
import LumiUI

/// 图标式菜单按钮：外观与 `LumiUI.AppIconButton` 一致（工具栏设置按钮同款），
/// 保留 `Menu` 的弹出行为。
///
/// `Menu` 无法直接包进 `AppIconButton`：borderless 菜单样式会把标签压成图标原始尺寸
/// （26×26 的标签被压成 20×14），改用 `.button` 菜单样式 + `.plain` 按钮样式后标签尺寸
/// 得到保留，外壳背景仍画在 `Menu` 外侧以与 `AppIconButton` 保持一致。
struct AppIconMenuButton<Content: View>: View {
    @LumiTheme private var theme: any LumiUITheme
    @LumiMotionPreferenceReader private var motionPreference

    let systemImage: String
    let label: String
    let accessibilityIdentifier: String
    let content: () -> Content

    @State private var isHovered = false

    init(
        systemImage: String,
        label: String,
        accessibilityIdentifier: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.systemImage = systemImage
        self.label = label
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textSecondary.opacity(0.8))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(theme.textSecondary.opacity(isHovered ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .stroke(isHovered ? theme.textSecondary.opacity(0.14) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(isHovered && motionPreference.allowsMotion ? LumiMotion.hoverScale : 1)
        .animation(motionPreference.allowsMotion ? LumiMotion.hover : nil, value: isHovered)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}