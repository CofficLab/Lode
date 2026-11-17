import Sparkle

/// 应用级自动更新入口：持有 Sparkle 标准更新控制器，随应用启动后台检查。
/// 更新源与签名公钥在 Info.plist（SUFeedURL / SUPublicEDKey）声明；
/// 发布与签名流程见 scripts/release/README.md。
@MainActor
final class UpdateController {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 「检查更新…」菜单项：用户主动触发，立即给出结果反馈。
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}