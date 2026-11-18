import KernelCore
import LumiUI
import ProviderSettingView
import ProviderToolbar
import SwiftUI

/// 工具栏设置按钮插件。
///
/// 在工具栏右侧注册齿轮按钮；点击发出「打开设置」通知，
/// 由宿主 App 监听并打开设置窗口，与具体窗口 id 解耦。
@MainActor
final class SettingsToolbarPlugin: SuperPlugin {
    let id = "com.coffic.lumi.plugin.toolbar-settings"
    let metadata = PluginMetadata(
        id: "com.coffic.lumi.plugin.toolbar-settings",
        name: pluginLocalizationMain.string("Settings"),
        description: "Adds a settings button to the trailing edge of the toolbar that opens the settings window.",
        category: .system,
        stage: .stable,
        policy: .alwaysOn
    )

    func onBoot(kernel: KernelCoreContainer) throws {
        guard let toolbar = kernel.resolveProvider((any ToolbarProviding).self) else { return }
        toolbar.addToolbarItems([
            ToolbarItem(
                id: "settings",
                title: pluginLocalizationMain.string("Settings"),
                placement: .trailing,
                category: .global,
                order: 300
            ) {
                AppIconButton(systemImage: "gearshape") {
                    NotificationCenter.default.post(
                        name: SettingViewNavigation.openSettingsNotification,
                        object: nil
                    )
                }
            },
        ])
    }

    func onShutdown(kernel: KernelCoreContainer) throws {
        kernel.resolveProvider((any ToolbarProviding).self)?
            .removeToolbarItems(ids: ["settings"])
    }
}