import Foundation

/// 为用户选择的文件持久化 security-scoped bookmark，使被记住的路径（SQL 文件、
/// SQLite 库、TLS/SSH 材料）在重启与文件移动后仍可访问，并为将来开启 App Sandbox
/// 做好准备。当前 App 刻意不沙箱（见 docs/security-model.md），bookmark 在此提供
/// 跨重启的稳健文件引用；沙箱开启后同一机制即为必需的文件访问凭据。
public final class SecurityScopedBookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard,
                keyPrefix: String = "DatabaseManager.fileBookmarks.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func key(for url: URL) -> String {
        keyPrefix + url.standardizedFileURL.path
    }

    /// 为用户选择的文件创建并持久化 security-scoped bookmark。创建失败（如文件
    /// 不存在）静默忽略——访问时回落原始路径，不阻断用户操作。
    public func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        lock.lock()
        defaults.set(data, forKey: key(for: url))
        lock.unlock()
    }

    /// 把存储的 bookmark 解析为可用 URL。无 bookmark 时回落原始 URL；bookmark
    /// 失效（stale，如文件被移动）时就地刷新后返回解析结果。
    public func resolve(_ url: URL) -> URL {
        lock.lock()
        let data = defaults.data(forKey: key(for: url))
        lock.unlock()
        guard let data else { return url }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data,
                                      options: .withSecurityScope,
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &stale) else {
            return url
        }
        if stale { remember(resolved) }
        return resolved
    }

    /// 在 security-scoped 访问下执行 `body`，结束后释放访问。无 bookmark 时
    /// startAccessing 返回 false，body 仍按原始路径执行（非沙箱下本就可达）。
    public func accessing<T>(_ url: URL, _ body: (URL) throws -> T) rethrows -> T {
        let resolved = resolve(url)
        let didStart = resolved.startAccessingSecurityScopedResource()
        defer { if didStart { resolved.stopAccessingSecurityScopedResource() } }
        return try body(resolved)
    }

    public func forget(_ url: URL) {
        lock.lock()
        defaults.removeObject(forKey: key(for: url))
        lock.unlock()
    }
}