import Foundation

/// 密码来源解析的运行时失败（区别于 ``ConnectionPasswordSourceError`` 的配置校验失败）。
/// 安全：``commandFailed`` 只携带退出码，绝不包含命令的 stdout/stderr（可能含敏感材料）。
enum PasswordSourceResolutionError: LocalizedError, Equatable {
    case fileUnreadable(path: String)
    case variableNotSet(name: String)
    case commandFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .fileUnreadable(let path): return "Could not read the password file at \(path)."
        case .variableNotSet(let name): return "Environment variable \(name) is not set."
        case .commandFailed(let status): return "The password command exited with status \(status)."
        }
    }
}

/// 把 ``ConnectionPasswordSource`` 解析成实际密码。依赖（环境变量表/文件读取/命令执行）
/// 均可注入，便于离线单测；默认实现读本机环境、读文件、经 `/bin/sh -c` 执行命令。
///
/// 交互式来源（``PasswordSourceKind/askEveryTime``）与 command 的用户确认闸门由
/// ``DatabaseViewModel`` 负责，本解析器只处理可静态求值的来源；askEveryTime 返回 nil。
///
/// 安全：命令输出仅作为密码返回，绝不写入日志；命令在后台任务执行，避免阻塞主线程。
struct PasswordSourceResolver: Sendable {
    var environment: [String: String]
    var readFile: @Sendable (String) throws -> String
    var runCommand: @Sendable (String) async throws -> String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: @escaping @Sendable (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
        runCommand: @escaping @Sendable (String) async throws -> String = PasswordSourceResolver.runShellCommand
    ) {
        self.environment = environment
        self.readFile = readFile
        self.runCommand = runCommand
    }

    func resolve(_ source: ConnectionPasswordSource, keychainPassword: String?) async throws -> String? {
        switch source.kind {
        case .keychain:
            return keychainPassword
        case .askEveryTime:
            return nil
        case .file:
            guard let path = source.filePath, !path.isEmpty else { throw ConnectionPasswordSourceError.missingFilePath }
            let raw: String
            do { raw = try readFile(path) } catch { throw PasswordSourceResolutionError.fileUnreadable(path: path) }
            return Self.trimTrailingNewlines(raw)
        case .environment:
            guard let name = source.variableName, !name.isEmpty else { throw ConnectionPasswordSourceError.missingVariableName }
            guard let value = environment[name] else { throw PasswordSourceResolutionError.variableNotSet(name: name) }
            return value
        case .command:
            guard let command = source.command, !command.isEmpty else { throw ConnectionPasswordSourceError.missingCommand }
            let raw = try await runCommand(command)
            return Self.trimTrailingNewlines(raw)
        }
    }

    /// 去掉尾部换行（secret 文件/命令输出通常以一个换行结尾）；保留其余空白以免误伤密码。
    /// 按 UTF-8 码元回退：CRLF 在 Swift 里是单一字素，逐 Character 判断会漏掉 `\r\n`。
    static func trimTrailingNewlines(_ string: String) -> String {
        let utf8 = string.utf8
        var end = utf8.endIndex
        while end > utf8.startIndex {
            let prev = utf8.index(before: end)
            let byte = utf8[prev]
            if byte == 0x0A || byte == 0x0D { end = prev } else { break }
        }
        return String(decoding: utf8[utf8.startIndex..<end], as: UTF8.self)
    }

    /// 默认命令执行器：`/bin/sh -c <command>`，捕获 stdout 作为密码。
    /// stderr 直接丢弃（nullDevice），输出绝不落日志；非零退出仅报退出码。
    /// 在 detached 任务中执行，避免 `waitUntilExit` 阻塞主线程（如等待 1Password 触摸）。
    static func runShellCommand(_ command: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PasswordSourceResolutionError.commandFailed(status: process.terminationStatus)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}