import Foundation
import KernelCore
import PluginRootView
import ProviderChatSection
import ProviderConversation
import ProviderSettingView
import ProviderStorage
import SwiftUI

/// KernelFactory — 内核工厂。
///
/// 负责创建 KernelCore 内核，装配各 Provider 并通过 `start(plugins:)`
/// 启动插件；主视图 / 设置视图组装委托 `ViewFactory`。
@MainActor
public enum KernelFactory {
    /// 使用宿主提供的 Provider / Plugin 工厂装配内核。
    public static func makeKernel(
        providerFactory: any ProviderFactory,
        pluginFactory: any PluginFactory,
        additionalPlugins: [any SuperPlugin] = []
    ) throws -> KernelCoreContainer {
        let kernel = KernelCoreContainer()
        try providerFactory.registerProviders(into: kernel)
        pluginFactory.didRegisterProviders(in: kernel)

        let plugins = makePlugins(
            providerFactory: providerFactory,
            pluginFactory: pluginFactory,
            additionalPlugins: additionalPlugins
        )
        if let storage = kernel.resolveProvider((any StorageProviding).self) {
            PluginDataMigrationCoordinator(storage: storage).run(for: plugins)
        }

        try kernel.start(plugins: plugins)
        resetSettingsSelectionToFirstEntry(in: kernel)

        if let chat = kernel.resolveProvider((any ChatSectionProviding).self),
           let conversations = kernel.resolveProvider((any ConversationManaging).self) {
            chat.bindConversationSelection(conversations)
        }

        return kernel
    }

    /// 组装完整的插件目录：`RootViewPlugin` + 工厂目录 + 宿主附加插件。
    public static func makePlugins(
        providerFactory: any ProviderFactory,
        pluginFactory: any PluginFactory,
        additionalPlugins: [any SuperPlugin] = []
    ) -> [any SuperPlugin] {
        [RootViewPlugin(provider: providerFactory.makeRootViewProvider())]
            + pluginFactory.makePlugins()
            + additionalPlugins
    }

    /// 设置窗口默认选中 order 最小的入口。
    private static func resetSettingsSelectionToFirstEntry(in kernel: KernelCoreContainer) {
        guard let settings = kernel.resolveProvider((any SettingViewProviding).self),
              let firstID = settings.entries.first?.id,
              settings.selectedEntryID != firstID
        else { return }
        settings.selectEntry(id: firstID)
    }

    /// 使用已装配的内核组装主视图。
    public static func makeMainView(kernel: KernelCoreContainer) throws -> AnyView {
        try makeMainView(kernel: kernel, viewFactory: DefaultViewFactory())
    }

    /// 使用自定义 `ViewFactory` 组装主视图。
    public static func makeMainView(
        kernel: KernelCoreContainer,
        viewFactory: any ViewFactory
    ) throws -> AnyView {
        try viewFactory.makeMainView(kernel: kernel)
    }

    /// 使用已装配的内核返回设置视图。
    public static func makeSettingsView(kernel: KernelCoreContainer) throws -> AnyView {
        try makeSettingsView(kernel: kernel, viewFactory: DefaultViewFactory())
    }

    /// 使用自定义 `ViewFactory` 组装设置视图。
    public static func makeSettingsView(
        kernel: KernelCoreContainer,
        viewFactory: any ViewFactory
    ) throws -> AnyView {
        try viewFactory.makeSettingsView(kernel: kernel)
    }
}
