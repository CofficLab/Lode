import AppKit
import Combine
import DatabaseManagerPlugin
import KernelCore
import LumiFactory
import SwiftUI

/// 应用入口：装配流水线、窗口壳、设置深链与外部文件打开排队全部由
/// LumiFactory 解释 `LodeHostManifest` 执行；本文件只负责把启动器接到
/// SwiftUI 入口，并追加数据库专属的应用命令。
@main
struct LodeApp: App {
    // delegate adaptor 必须挂在 @main 根 App 上：SwiftUI 只为根 App 安装
    // NSApplicationDelegateAdaptor，放在嵌套结构上不会生效。
    @NSApplicationDelegateAdaptor private var appDelegate: HostAppDelegate

    init() {
        // 禁用窗口状态恢复必须在根 App.init 写入（恢复发生在 delegate 回调之前）。
        HostAppDelegate.prepareForLaunch()
        #if DEBUG
        // XCTest 注入宿主时，App 自身启动早于任何测试 setUp：提前隔离数据根，
        // 避免启动装配读真实 UserDefaults/Keychain（授权弹窗会挂起启动与测试连接）。
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil,
           ProcessInfo.processInfo.environment["LODE_UI_TEST_DATA_ROOT"] == nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LodeXCTestHost-\(UUID().uuidString)", isDirectory: true)
            setenv("LODE_UI_TEST_DATA_ROOT", root.path, 1)
        }
        MainThreadStallMonitor.shared.start()
        #endif
        LodeAssembly.startLaunchMetrics()
        appDelegate.bootstrapper = LodeAssembly.bootstrapper
    }

    var body: some Scene {
        // 单例主窗口（与 GitOK / Wakey 一致）：共享壳启动时会显式开窗，
        // WindowGroup 拓扑下 openWindow(id:) 会再建一个实例，造成双主窗口。
        HostMacScenes(bootstrapper: LodeAssembly.bootstrapper).body
            .commands {
                DatabaseGridEditCommands()
                DatabaseSQLFileCommands()
                DatabaseQueryCommands()
            }
    }
}

/// 宿主级装配单例：App.init 可能被 SwiftUI 多次求值，启动器必须经单例创建，
/// 保证视图持有的与注入 AppDelegate 的是同一个实例。
@MainActor
enum LodeAssembly {
    static let updates = UpdateController()
    static let bootstrapper = KernelBootstrapper(
        manifest: LodeHostManifest.make {
            LodeAssembly.updates.checkForUpdates()
        }
    )

    private static var assemblyToken: String?
    private static var stateSubscription: AnyCancellable?

    /// 装配耗时测量：init 处开表，内核就绪（或失败）时收表。
    /// 首窗构建耗时由清单的 `makeMainView` 钩子测量。
    static func startLaunchMetrics() {
        assemblyToken = LaunchPerformance.shared.begin(.assembly)
        stateSubscription = bootstrapper.$state.sink { state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    if let token = assemblyToken {
                        LaunchPerformance.shared.end(token)
                        assemblyToken = nil
                    }
                case .failed:
                    if let token = assemblyToken {
                        LaunchPerformance.shared.cancel(token)
                        assemblyToken = nil
                    }
                default:
                    break
                }
            }
        }
    }
}