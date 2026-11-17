import Foundation
import Sparkle

/// 演练结果汇聚点：驱动回调线程写入，主循环轮询读取。
final class DrillState: @unchecked Sendable {
    private let lock = NSLock()
    private var _done = false
    private var _success = false
    private var _message = ""

    var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
    var success: Bool { lock.lock(); defer { lock.unlock() }; return _success }
    var message: String { lock.lock(); defer { lock.unlock() }; return _message }

    func finish(success: Bool, message: String) {
        lock.lock()
        _done = true
        _success = success
        _message = message
        lock.unlock()
    }
}

/// 无头用户驱动：自动同意检查/下载/安装，使升级演练可以无人值守跑完。
final class HeadlessUserDriver: NSObject, SPUUserDriver {
    let state: DrillState
    let expectedVersion: String
    let install: Bool

    init(state: DrillState, expectedVersion: String, install: Bool) {
        self.state = state
        self.expectedVersion = expectedVersion
        self.install = install
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        print("drill: checking for updates")
    }

    func showUpdateFound(_ appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        print("drill: update found version=\(version)")
        guard version == expectedVersion || appcastItem.versionString == expectedVersion else {
            state.finish(success: false, message: "unexpected update version \(version), expected \(expectedVersion)")
            reply(.dismiss)
            return
        }
        reply(install ? .install : .skip)
        if !install {
            state.finish(success: true, message: "update \(version) found and offered (download-only drill)")
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state.finish(success: false, message: "no update found: \(error.localizedDescription)")
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state.finish(success: false, message: "updater error: \(error.localizedDescription)")
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        print("drill: download initiated")
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        print("drill: expected content length \(expectedContentLength)")
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {
        print("drill: extracting update")
    }
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReadyToInstallAndRelaunch(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        print("drill: ready to install")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        print("drill: installing (applicationTerminated=\(applicationTerminated))")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        state.finish(success: true, message: "update installed (relaunched=\(relaunched))")
        acknowledgement()
    }

    func dismissUpdateInstallation() {}
    func showUpdateInFocus() {}
}

/// 演练委托：把更新源指向本地 appcast，并禁止演练结束后拉起 GUI。
final class DrillDelegate: NSObject, SPUUpdaterDelegate {
    let feedURL: String

    init(feedURL: String) {
        self.feedURL = feedURL
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("drill: valid update \(item.displayVersionString)")
    }
}