import AppKit
import FactoryDatabaseManager
import KernelCore
import SwiftUI

@MainActor
private final class LodeFileOpenAgent: NSObject, NSApplicationDelegate {
    private static var kernel: KernelCoreContainer?
    private static var pendingURLs: [URL] = []

    static func configure(kernel: KernelCoreContainer) {
        Self.kernel = kernel
        let queuedURLs = Self.pendingURLs
        Self.pendingURLs = []
        queuedURLs.forEach { _ = FactoryDatabaseManager.openExternalFile($0, kernel: kernel) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Self.open(url) }
    }

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        Self.open(URL(fileURLWithPath: filename))
        return true
    }

    private static func open(_ url: URL) {
        guard let kernel else {
            pendingURLs.append(url)
            return
        }
        _ = FactoryDatabaseManager.openExternalFile(url, kernel: kernel)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
    }
}

@main
struct LodeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: LodeFileOpenAgent

    private let updates = UpdateController()
    private let kernel: KernelCoreContainer?
    private let mainView: AnyView
    private let settingsView: AnyView

    init() {
        #if DEBUG
        MainThreadStallMonitor.shared.start()
        #endif
        var assembled: KernelCoreContainer?
        LaunchPerformance.shared.measure(.assembly) {
            assembled = try? FactoryDatabaseManager.makeKernel()
        }
        kernel = assembled
        guard let kernel = assembled else {
            mainView = AnyView(Text("Failed to assemble Lode"))
            settingsView = AnyView(Text("Failed to assemble settings"))
            return
        }
        LodeFileOpenAgent.configure(kernel: kernel)
        var firstWindow: AnyView?
        LaunchPerformance.shared.measure(.firstWindow) {
            firstWindow = try? FactoryDatabaseManager.makeMainView(kernel: kernel)
        }
        mainView = firstWindow.map { AnyView(MainSceneHostView(content: $0, kernel: kernel)) }
            ?? AnyView(Text("Failed to assemble Lode"))
        settingsView = (try? FactoryDatabaseManager.makeSettingsView(kernel: kernel))
            ?? AnyView(Text("Failed to assemble settings"))
    }

    var body: some Scene {
        WindowGroup("Lode", id: "lode.main") {
            mainView
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(String(localized: "Settings…")) {
                    NotificationCenter.default.post(
                        name: SettingViewNavigation.openSettingsNotification,
                        object: nil
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
                Button(String(localized: "Check for Updates…")) {
                    updates.checkForUpdates()
                }
            }
            DatabaseGridEditCommands()
            DatabaseSQLFileCommands()
            DatabaseQueryCommands()
        }

        Window("Settings", id: "lode.settings") {
            settingsView
        }
        .defaultSize(width: 960, height: 600)
    }
}

/// 主窗口宿主视图：监听「打开设置」通知（工具栏按钮 / 菜单 / 插件深链共用），
/// 按需选中指定设置入口后打开设置窗口。
@MainActor
private struct MainSceneHostView: View {
    let content: AnyView
    let kernel: KernelCoreContainer?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: SettingViewNavigation.openSettingsNotification)
            ) { notification in
                if let kernel,
                   let settings = kernel.resolveProvider((any SettingViewProviding).self),
                   let entryID = notification.userInfo?[SettingViewNavigation.entryIDUserInfoKey] as? String,
                   settings.entries.contains(where: { $0.id == entryID }) {
                    settings.selectEntry(id: entryID)
                }
                openWindow(id: "lode.settings")
            }
    }
}
