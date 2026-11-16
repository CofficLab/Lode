import Foundation

/// 连接密码的来源方式。整体以 JSON 存进 ``DatabaseConfig/options`` 的 `"passwordSource"` 键。
///
/// - ``keychain``：默认。密码存系统 Keychain（``DatabaseConnectionStore``），配置本体不含明文。
/// - ``file``：从文件读取（如挂载的 secret 文件），取内容并去掉尾部换行。
/// - ``environment``：从环境变量读取。
/// - ``command``：本机执行一条命令取其 stdout（如 `op read ...` / `security find-generic-password ...`）。
///   执行前需用户确认；命令输出绝不写入日志。
/// - ``askEveryTime``：每次连接时弹窗询问，密码仅存内存、不落盘。
///
/// 仅对需要密码的网络引擎（MySQL/PostgreSQL/Redis）有意义；SQLite 本地文件无密码。
public enum PasswordSourceKind: String, Codable, CaseIterable, Sendable {
    case keychain
    case file
    case environment
    case command
    case askEveryTime

    public var displayTitle: String {
        switch self {
        case .keychain: return "Keychain"
        case .file: return "File"
        case .environment: return "Environment Variable"
        case .command: return "Command"
        case .askEveryTime: return "Ask Every Time"
        }
    }

    /// 表单里来源选择器下方的一行说明（本地化键）。
    public var helpText: String {
        switch self {
        case .keychain: return "Stored securely in the system Keychain."
        case .file: return "Read the password from a file, e.g. a mounted secret."
        case .environment: return "Read the password from an environment variable."
        case .command: return "Run a command on your Mac to get the password. You confirm each time."
        case .askEveryTime: return "Ask for the password each time you connect. Never stored."
        }
    }
}

public struct ConnectionPasswordSource: Codable, Hashable, Sendable {
    public var kind: PasswordSourceKind
    /// ``file`` 来源的文件路径。
    public var filePath: String?
    /// ``environment`` 来源的环境变量名。
    public var variableName: String?
    /// ``command`` 来源的 shell 命令。
    public var command: String?

    public init(
        kind: PasswordSourceKind = .keychain,
        filePath: String? = nil,
        variableName: String? = nil,
        command: String? = nil
    ) {
        self.kind = kind
        self.filePath = filePath
        self.variableName = variableName
        self.command = command
    }

    /// 是否为默认（Keychain）来源——默认来源不写入 options，回退既有行为。
    public var isDefault: Bool { kind == .keychain }
}

public enum ConnectionPasswordSourceError: LocalizedError, Equatable {
    case missingFilePath
    case missingVariableName
    case missingCommand

    public var errorDescription: String? {
        switch self {
        case .missingFilePath: return "A password file path is required."
        case .missingVariableName: return "An environment variable name is required."
        case .missingCommand: return "A command is required."
        }
    }
}

public extension ConnectionPasswordSource {
    /// 校验并归一化（trim 路径/变量名/命令；按来源类型要求必填字段）。
    func validated() throws -> ConnectionPasswordSource {
        var copy = self
        copy.filePath = filePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.variableName = variableName?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.command = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .keychain, .askEveryTime:
            break
        case .file:
            guard let path = copy.filePath, !path.isEmpty else { throw ConnectionPasswordSourceError.missingFilePath }
        case .environment:
            guard let name = copy.variableName, !name.isEmpty else { throw ConnectionPasswordSourceError.missingVariableName }
        case .command:
            guard let command = copy.command, !command.isEmpty else { throw ConnectionPasswordSourceError.missingCommand }
        }
        return copy
    }
}

public extension DatabaseConfig {
    private static let passwordSourceKey = "passwordSource"

    /// 当前配置的密码来源。未设置或 JSON 损坏时返回 nil（视为默认 Keychain）。
    var passwordSource: ConnectionPasswordSource? {
        guard let raw = options?[Self.passwordSourceKey], let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ConnectionPasswordSource.self, from: data)
    }

    /// 返回一份应用了新密码来源的副本（nil 或默认 Keychain 来源移除该键，回退既有行为）。
    func withPasswordSource(_ source: ConnectionPasswordSource?) -> DatabaseConfig {
        var copy = self
        var opts = copy.options ?? [:]
        if let source, !source.isDefault, let data = try? JSONEncoder().encode(source),
           let json = String(data: data, encoding: .utf8) {
            opts[Self.passwordSourceKey] = json
        } else {
            opts.removeValue(forKey: Self.passwordSourceKey)
        }
        copy.options = opts.isEmpty ? nil : opts
        return copy
    }
}