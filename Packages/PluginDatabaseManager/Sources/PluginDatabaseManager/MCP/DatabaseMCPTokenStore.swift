import Foundation
import Security

/// MCP server 的访问令牌存储。
///
/// 令牌以 0600 权限落盘（目录 0700），server 启动时要求环境变量出示同一令牌，
/// 恒时比较防止计时侧信道。`--generate-token` 生成/轮换并一次性打印。
public struct DatabaseMCPTokenStore {
    public static let tokenFileEnvironmentKey = "LODE_MCP_TOKEN_FILE"
    public static let tokenEnvironmentKey = "LODE_MCP_TOKEN"

    public let fileURL: URL

    /// - Parameter directory: 令牌目录；缺省取应用支持目录，环境变量
    ///   ``tokenFileEnvironmentKey`` 可指向自定义令牌文件（测试与多实例隔离用）。
    public init(directory: URL? = nil) {
        if let override = ProcessInfo.processInfo.environment[Self.tokenFileEnvironmentKey], !override.isEmpty {
            self.fileURL = URL(fileURLWithPath: override)
        } else if let directory {
            self.fileURL = directory.appendingPathComponent("token")
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("Lode", isDirectory: true)
                .appendingPathComponent("DatabaseMCP", isDirectory: true)
                .appendingPathComponent("token")
        }
    }

    /// 生成 32 字节加密随机令牌（hex），写入磁盘并返回。
    @discardableResult
    public func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileReadUnknown)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(token.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return token
    }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let token = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// 恒时比较；未配置令牌或出示为空一律拒绝。
    public func verify(_ presented: String?) -> Bool {
        guard let presented, !presented.isEmpty,
              let expected = try? load(), !expected.isEmpty else {
            return false
        }
        let lhs = Array(presented.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}