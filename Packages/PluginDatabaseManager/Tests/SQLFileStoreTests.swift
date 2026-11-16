import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-6 SQL 文件磁盘 I/O：UTF-8 往返、原子写、快照、缺失文件分支（临时文件）。

@Suite struct SQLFileStoreTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lode-sqlstore-\(UUID().uuidString).sql")
    }

    @Test func readWriteRoundTripUTF8() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let text = "SELECT '日本', '😀';\n-- 注释\n"
        try SQLFileStore.write(text, to: url)
        #expect(try SQLFileStore.read(url) == text)
    }

    @Test func snapshotReflectsContentAndDate() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        let s = try #require(SQLFileStore.snapshot(of: url))
        #expect(s.contentHash == SQLFileContentHash.hash("SELECT 1;"))
        #expect(s.modificationDate != nil)
    }

    @Test func writeUpdatesContentHash() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("SELECT 1;", to: url)
        let before = try #require(SQLFileStore.snapshot(of: url))
        try SQLFileStore.write("SELECT 2;", to: url)
        let after = try #require(SQLFileStore.snapshot(of: url))
        #expect(before.contentHash != after.contentHash)
    }

    @Test func snapshotNilForMissingFile() {
        #expect(SQLFileStore.snapshot(of: tempURL()) == nil)
    }

    @Test func modificationDateNilForMissingFile() {
        #expect(SQLFileStore.modificationDate(of: tempURL()) == nil)
    }

    @Test func readThrowsForMissingFile() {
        let url = tempURL()
        #expect(throws: (any Error).self) { try SQLFileStore.read(url) }
    }

    @Test func overwritePreservesLatestContent() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try SQLFileStore.write("first", to: url)
        try SQLFileStore.write("second", to: url)
        #expect(try SQLFileStore.read(url) == "second")
    }
}