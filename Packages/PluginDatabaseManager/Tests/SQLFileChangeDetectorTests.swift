import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-6 外部变更判定（纯函数）：以内容哈希为准，忽略仅 mtime 变化的 touch。

@Suite struct SQLFileChangeDetectorTests {
    private func snap(_ date: Date?, _ hash: UInt64) -> SQLFileSnapshot {
        SQLFileSnapshot(modificationDate: date, contentHash: hash)
    }

    @Test func unchangedWhenBaselineNil() {
        #expect(SQLFileChangeDetector.classify(baseline: nil, current: snap(Date(), 1)) == .unchanged)
    }

    @Test func unchangedWhenBothNil() {
        #expect(SQLFileChangeDetector.classify(baseline: nil, current: nil) == .unchanged)
    }

    @Test func missingWhenCurrentNil() {
        #expect(SQLFileChangeDetector.classify(baseline: snap(Date(), 1), current: nil) == .missing)
    }

    @Test func unchangedWhenHashEqual() {
        let d = Date()
        #expect(SQLFileChangeDetector.classify(baseline: snap(d, 42), current: snap(d, 42)) == .unchanged)
    }

    @Test func modifiedWhenHashDiffers() {
        let d = Date()
        #expect(SQLFileChangeDetector.classify(baseline: snap(d, 42), current: snap(d, 43)) == .modified)
    }

    @Test func unchangedWhenOnlyDateDiffers() {
        let a = Date(timeIntervalSince1970: 1)
        let b = Date(timeIntervalSince1970: 999)
        #expect(SQLFileChangeDetector.classify(baseline: snap(a, 42), current: snap(b, 42)) == .unchanged)
    }

    @Test func modifiedWhenHashDiffersEvenIfDateSame() {
        let d = Date()
        #expect(SQLFileChangeDetector.classify(baseline: snap(d, 1), current: snap(d, 2)) == .modified)
    }
}

// 稳定 FNV-1a 64 位哈希：跨进程一致，含已知测试向量。

@Suite struct SQLFileContentHashTests {
    @Test func stableForSameText() {
        #expect(SQLFileContentHash.hash("SELECT 1;") == SQLFileContentHash.hash("SELECT 1;"))
    }

    @Test func differsForDifferentText() {
        #expect(SQLFileContentHash.hash("SELECT 1;") != SQLFileContentHash.hash("SELECT 2;"))
    }

    @Test func emptyVersusWhitespace() {
        #expect(SQLFileContentHash.hash("") == SQLFileContentHash.hash(""))
        #expect(SQLFileContentHash.hash("") != SQLFileContentHash.hash(" "))
    }

    @Test func multibyteAndEmoji() {
        #expect(SQLFileContentHash.hash("SELECT '日本';") == SQLFileContentHash.hash("SELECT '日本';"))
        #expect(SQLFileContentHash.hash("😀") != SQLFileContentHash.hash("😁"))
    }

    @Test func knownFNVVectors() {
        #expect(SQLFileContentHash.hash("") == 0xcbf2_9ce4_8422_2325)
        #expect(SQLFileContentHash.hash("a") == 0xaf63_dc4c_8601_ec8c)
    }
}