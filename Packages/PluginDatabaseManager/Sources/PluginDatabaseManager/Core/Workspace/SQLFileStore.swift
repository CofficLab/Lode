import Foundation

/// SQL 文件读写与磁盘快照（UTF-8、原子写）。
///
/// 与编辑器内核的文件监听相互独立：本插件不依赖编辑器内核包，
/// 故在此自持一份轻量实现，纯磁盘 I/O，便于用临时文件做集成测试。
public enum SQLFileStore {
    public static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 读取内容 + 修改时间生成快照；文件缺失或不可读返回 nil。
    public static func snapshot(of url: URL) -> SQLFileSnapshot? {
        guard let text = try? read(url) else { return nil }
        return SQLFileSnapshot(
            modificationDate: modificationDate(of: url),
            contentHash: SQLFileContentHash.hash(text)
        )
    }
}