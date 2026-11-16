import Foundation

/// SQL 文件磁盘基线：修改时间 + 内容哈希。
///
/// 打开/写回时记录，用于检测外部修改。变更判定以内容哈希为准（mtime 在快速写入
/// 或属性缓存下可能不变，不可靠）；修改时间仅作元信息随基线持久化。
public struct SQLFileSnapshot: Codable, Equatable, Sendable {
    public let modificationDate: Date?
    public let contentHash: UInt64

    public init(modificationDate: Date?, contentHash: UInt64) {
        self.modificationDate = modificationDate
        self.contentHash = contentHash
    }
}

/// 稳定的 FNV-1a 64 位内容哈希（跨进程一致，可随基线持久化后跨重启比对）。
public enum SQLFileContentHash {
    public static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// 文件相对基线的变更类别。
public enum SQLFileChange: Equatable, Sendable {
    case unchanged
    case modified
    case missing
}

/// 纯函数变更判定：以内容哈希为准（忽略仅 mtime 变化的 touch，避免误报），
/// 基线缺失视为无文件关联，当前快照缺失视为文件被删除/移走。
public enum SQLFileChangeDetector {
    public static func classify(baseline: SQLFileSnapshot?, current: SQLFileSnapshot?) -> SQLFileChange {
        guard let baseline else { return .unchanged }
        guard let current else { return .missing }
        return current.contentHash == baseline.contentHash ? .unchanged : .modified
    }
}

/// 活动标签的文件冲突状态（驱动 Reload / Save As 横幅）。
public struct SQLFileConflict: Equatable, Sendable {
    public let url: URL
    public let change: SQLFileChange
    public let isDirty: Bool

    public init(url: URL, change: SQLFileChange, isDirty: Bool) {
        self.url = url
        self.change = change
        self.isDirty = isDirty
    }
}