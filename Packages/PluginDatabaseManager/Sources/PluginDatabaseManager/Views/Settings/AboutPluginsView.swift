import LumiUI
import SwiftUI

/// 关于插件 —— 以「Kernel + Plugin 架构」为主轴的落地页。
///
/// 参照 Lumi 兄弟项目的设置 → 关于插件页面，介绍 Lode 的插件体系、
/// 宿主集成点与已挂载插件目录。
public struct AboutPluginsView: View {
    @LumiTheme private var theme

    /// 当前已挂载的插件列表（id + 名称）。
    private let plugins: [(id: String, name: String)]

    public init(plugins: [(id: String, name: String)] = []) {
        self.plugins = plugins
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            architectureSpotlight
            hostIntegrationSection
            pluginDirectorySection
        }
    }

    // MARK: - Hero

    private var hero: some View {
        LandingHero(
            icon: "puzzlepiece.extension",
            accent: theme.primary,
            tagline: L("用 Kernel 管理生命周期，用 Plugin 贡献能力。每一个插件都是可独立启停的模块，在统一的事件总线中协同工作。"),
            chips: [L("Kernel + Plugins"), L("all observable.")],
            metrics: [
                .init(value: "onRegister → onBoot → onReady", label: L("生命周期")),
                .init(value: "Provider", label: L("能力协议")),
                .init(value: "SuperPlugin", label: L("插件基类"))
            ]
        )
        .landingAppear()
    }

    // MARK: - 插件架构签名

    private var architectureSpotlight: some View {
        LandingSpotlight(
            icon: "square.grid.3x3.square",
            tint: theme.primary,
            title: L("插件不是回调，是独立模块"),
            message: L("每个插件声明元数据、依赖与启停策略；Kernel 统一校验、排序、原子启动。插件之间通过 Provider 协议解耦，通过事件总线异步协作。")
        ) {
            HStack(spacing: 6) {
                AppTag(L("声明式"), style: .subtle)
                AppTag(L("可组合"), style: .subtle)
                AppTag(L("可观测"), style: .subtle)
            }
            .padding(.top, 4)
        }
        .landingAppear(delay: 0.05)
    }

    // MARK: - 宿主集成点

    private var hostIntegrationSection: some View {
        LandingSection(title: L("宿主集成点"), icon: "link.circle") {
            LandingFeatureGrid(items: [
                .init(icon: "macwindow", tint: theme.primary,
                      title: L("根视图"),
                      description: L("Workbench 布局：Rail 侧栏 + 对话尾栏 + 底部面板。")),
                .init(icon: "rectangle.split.3x1", tint: theme.info,
                      title: L("内容区"),
                      description: L("数据库浏览器、SQL 编辑器、表格编辑等核心工作区。")),
                .init(icon: "text.bubble", tint: theme.warning,
                      title: L("对话"),
                      description: L("Agent 对话、消息渲染、流式输出、工具调用。")),
                .init(icon: "gearshape", tint: theme.success,
                      title: L("设置"),
                      description: L("各插件在设置窗口贡献自己的面板与关于页。")),
                .init(icon: "hammer", tint: theme.error,
                      title: L("工具"),
                      description: L("Agent 可调用的工具集，由插件注册并管理。")),
                .init(icon: "bolt", tint: theme.primary,
                      title: L("提示建议"),
                      description: L("快捷入口与建议词，深链到设置页或触发 Agent 动作。"))
            ])
        }
        .landingAppear(delay: 0.1)
    }

    // MARK: - 插件目录

    private var pluginDirectorySection: some View {
        let items: [LandingInventoryItem] = plugins.map { plugin in
            LandingInventoryItem(
                icon: "puzzlepiece.extension",
                title: plugin.name,
                description: plugin.id
            )
        }

        return LandingSection(title: L("已挂载插件"), icon: "list.bullet.rectangle") {
            LandingInventory(tint: theme.primary, items: items)
        }
        .landingAppear(delay: 0.15)
    }

    // MARK: - Localization

    private func L(_ key: String) -> String {
        pluginLocalization.string(key)
    }
}

#Preview {
    ScrollView {
        AboutPluginsView(plugins: [
            ("com.coffic.lumi.plugin.setting-view", "设置视图"),
            ("com.coffic.lumi.plugin.message-sender", "消息发送"),
            ("com.coffic.lumi.plugin.database-manager", "数据库管理"),
            ("com.coffic.lumi.plugin.code-editor", "代码编辑器")
        ])
            .padding(22)
    }
    .frame(width: 560, height: 1200)
}
