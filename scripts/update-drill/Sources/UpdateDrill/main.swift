import Foundation
import Sparkle

// 用法: UpdateDrill --app <Lode.app 路径> --feed <appcast URL> --expect <新版本号> [--no-install] [--status-file <路径>] [--log-file <路径>]
// 对指定 App 副本驱动一次完整 Sparkle 升级：发现 → 下载 → 验签 → 安装，
// 结束后核对副本的 CFBundleShortVersionString 是否升到期望版本。
// 必须以 App bundle 形式经 LaunchServices 启动（drill-update.sh 负责打包）：
// Sparkle 安装器依赖 AuthorizationCreate，裸 CLI 进程在新型 macOS 上会被拒绝。

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

let statusFile = arg("--status-file")
// LaunchServices 启动时 stdout 不落终端，重定向到日志文件便于演练留痕。
if let logFile = arg("--log-file") {
    freopen(logFile, "w", stdout)
    freopen(logFile, "w", stderr)
}
func finish(_ code: Int32) -> Never {
    if let statusFile {
        try? "\(code)".write(toFile: statusFile, atomically: true, encoding: .utf8)
    }
    exit(code)
}

guard let appPath = arg("--app"), let feed = arg("--feed"), let expected = arg("--expect") else {
    FileHandle.standardError.write(Data("usage: UpdateDrill --app <path.app> --feed <url> --expect <version> [--no-install] [--status-file <path>] [--log-file <path>]\n".utf8))
    finish(2)
}
let install = !CommandLine.arguments.contains("--no-install")
let appURL = URL(fileURLWithPath: appPath)
guard let bundle = Bundle(url: appURL) else {
    FileHandle.standardError.write(Data("cannot open bundle at \(appPath)\n".utf8))
    finish(2)
}
let oldVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
print("drill: host version=\(oldVersion) feed=\(feed) expect=\(expected) install=\(install)")

let state = DrillState()
let driver = HeadlessUserDriver(state: state, expectedVersion: expected, install: install)
let delegate = DrillDelegate(feedURL: feed)
let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
updater.automaticallyDownloadsUpdates = install

do {
    try updater.start()
} catch {
    FileHandle.standardError.write(Data("updater start failed: \(error.localizedDescription)\n".utf8))
    finish(1)
}
updater.checkForUpdates()

let deadline = Date().addingTimeInterval(240)
while !state.done && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
}

if !state.done {
    print("DRILL FAIL: timed out waiting for updater")
    finish(1)
}
guard state.success else {
    print("DRILL FAIL: \(state.message)")
    finish(1)
}

if install {
    // 直接读磁盘上的 Info.plist：NSBundle 会缓存进程启动时的旧字典。
    let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
    let installed = (NSDictionary(contentsOf: plistURL)?["CFBundleShortVersionString"] as? String) ?? "?"
    guard installed == expected else {
        print("DRILL FAIL: installed version \(installed) != expected \(expected)")
        finish(1)
    }
    print("DRILL PASS: \(oldVersion) -> \(installed) (\(state.message))")
} else {
    print("DRILL PASS: \(state.message)")
}
finish(0)