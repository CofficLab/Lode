import Foundation
import Testing
@testable import DatabaseManagerPlugin

// security-scoped bookmark 往返：记住用户选择的文件 → 跨「重启」（新实例共享
// UserDefaults）解析 → 在访问下读写 → 释放。无 bookmark/文件缺失时回落原始路径。
@Suite struct SecurityScopedBookmarkStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "bookmark-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeFile(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "bm-\(UUID().uuidString).sql")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func roundTripResolvesAndReadsUnderAccess() throws {
        let url = try makeFile("SELECT 1;")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SecurityScopedBookmarkStore(defaults: freshDefaults())
        store.remember(url)
        let text = try store.accessing(url) { try String(contentsOf: $0, encoding: .utf8) }
        #expect(text == "SELECT 1;")
    }

    @Test func bookmarkSurvivesRelaunch() throws {
        let url = try makeFile("SELECT 2;")
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = freshDefaults()
        SecurityScopedBookmarkStore(defaults: defaults).remember(url)
        // 新实例共享同一 UserDefaults，模拟 App 重启后恢复被记住的文件。
        let restored = SecurityScopedBookmarkStore(defaults: defaults)
        let text = try restored.accessing(url) { try String(contentsOf: $0, encoding: .utf8) }
        #expect(text == "SELECT 2;")
    }

    @Test func resolveWithoutBookmarkReturnsOriginal() throws {
        let url = try makeFile("x")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SecurityScopedBookmarkStore(defaults: freshDefaults())
        #expect(store.resolve(url).standardizedFileURL == url.standardizedFileURL)
        // 无 bookmark 时 accessing 仍按原始路径执行。
        let text = try store.accessing(url) { try String(contentsOf: $0, encoding: .utf8) }
        #expect(text == "x")
    }

    @Test func missingFileFallsBackToOriginal() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "bm-missing-\(UUID().uuidString).sql")
        let store = SecurityScopedBookmarkStore(defaults: freshDefaults())
        store.remember(url) // 文件不存在：创建失败被静默忽略
        #expect(store.resolve(url).standardizedFileURL == url.standardizedFileURL)
    }

    @Test func forgetRemovesBookmark() throws {
        let url = try makeFile("y")
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = freshDefaults()
        let store = SecurityScopedBookmarkStore(defaults: defaults)
        store.remember(url)
        store.forget(url)
        // forget 后新实例不再持有 bookmark，解析回落原始路径。
        let restored = SecurityScopedBookmarkStore(defaults: defaults)
        #expect(restored.resolve(url).standardizedFileURL == url.standardizedFileURL)
    }

    @Test func accessingReturnsBodyValueAndRethrows() throws {
        let url = try makeFile("z")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SecurityScopedBookmarkStore(defaults: freshDefaults())
        store.remember(url)
        let count = try store.accessing(url) { try String(contentsOf: $0, encoding: .utf8).count }
        #expect(count == 1)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try store.accessing(url) { _ in throw Boom() }
        }
    }

    @Test func writeUnderAccessPersists() throws {
        let url = try makeFile("old")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SecurityScopedBookmarkStore(defaults: freshDefaults())
        store.remember(url)
        try store.accessing(url) { try "new".write(to: $0, atomically: true, encoding: .utf8) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }
}