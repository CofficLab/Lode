import Foundation
import Sparkle

// 用法: UpdateDrill --app <Lode.app 路径> --feed <appcast URL> --expect <新版本号> [--no-install]
// 对指定 App 副本驱动一次完整 Sparkle 升级：发现 → 下载 → 验签 → 安装，
// 结束后核对副本的 CFBundleShortVersionString 是否升到期望版本。

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

guard let appPath = arg("--app"), let feed = arg("--feed"), let expected = arg("--expect") else {
    FileHandle.standardError.write(Data("usage: UpdateDrill --app <path.app> --feed <url> --expect <version> [--no-install]\n".utf8))
    exit(2)
}
let install = !CommandLine.arguments.contains("--no-install")
let appURL = URL(fileURLWithPath: appPath)
guard let bundle = Bundle(url: appURL) else {
    FileHandle.standardError.write(Data("cannot open bundle at \(appPath)\n".utf8))
    exit(2)
}
let oldVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
print("drill: host version=\(oldVersion) feed=\(feed) expect=\(expected) install=\(install)")

let state = DrillState()
let driver = HeadlessUserDriver(state: state, expectedVersion: expected, install: install)
let delegate = DrillDelegate(feedURL: feed)
let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
updater.automaticallyDownloadsUpdates = install

do {
    try updater.startUpdater()
} catch {
    FileHandle.standardError.write(Data("startUpdater failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
updater.checkForUpdates()

let deadline = Date().addingTimeInterval(240)
while !state.done && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
}

if !state.done {
    print("DRILL FAIL: timed out waiting for updater")
    exit(1)
}
guard state.success else {
    print("DRILL FAIL: \(state.message)")
    exit(1)
}

if install {
    let installed = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    guard installed == expected else {
        print("DRILL FAIL: installed version \(installed) != expected \(expected)")
        exit(1)
    }
    print("DRILL PASS: \(oldVersion) -> \(installed) (\(state.message))")
} else {
    print("DRILL PASS: \(state.message)")
}
exit(0)