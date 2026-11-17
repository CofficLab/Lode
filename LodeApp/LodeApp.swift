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
        mainView = firstWindow ?? AnyView(Text("Failed to assemble Lode"))
        settingsView = (try? FactoryDatabaseManager.makeSettingsView(kernel: kernel))
            ?? AnyView(Text("Failed to assemble settings"))
    }

    var body: some Scene {
        WindowGroup("Lode", id: "lode.main") {
            mainView
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            DatabaseGridEditCommands()
            DatabaseSQLFileCommands()
            DatabaseQueryCommands()
        }

        Window("Settings", id: "lode.settings") {
            settingsView
        }
        .defaultSize(width: 780, height: 600)
    }
}
