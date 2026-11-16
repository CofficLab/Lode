import Foundation

/// hex 视图的一行：偏移 + 十六进制列 + ASCII 列。
public struct HexRow: Sendable, Equatable {
    public let offset: Int
    public let hex: String
    public let ascii: String

    public init(offset: Int, hex: String, ascii: String) {
        self.offset = offset
        self.hex = hex
        self.ascii = ascii
    }
}

/// BLOB hex 视图的纯函数格式化：按行号按需计算，
/// 大 BLOB 不必一次性生成全部行（视图用 LazyVStack 逐行取）。
public enum HexFormatter {
    public static let defaultBytesPerRow = 16

    public static func rowCount(_ data: Data, bytesPerRow: Int = defaultBytesPerRow) -> Int {
        (data.count + bytesPerRow - 1) / bytesPerRow
    }

    /// 第 `rowIndex` 行（从 0 起）；末行不足时 hex 列补空格对齐。
    public static func row(_ data: Data, at rowIndex: Int, bytesPerRow: Int = defaultBytesPerRow) -> HexRow {
        let offset = rowIndex * bytesPerRow
        let start = data.startIndex + offset
        let end = min(start + bytesPerRow, data.endIndex)
        var hexParts: [String] = []
        var ascii = ""
        var index = start
        while index < end {
            let byte = data[index]
            hexParts.append(String(format: "%02x", byte))
            ascii.append(byte >= 0x20 && byte <= 0x7E ? String(UnicodeScalar(byte)) : ".")
            index += 1
        }
        while hexParts.count < bytesPerRow { hexParts.append("  ") }
        return HexRow(offset: offset, hex: hexParts.joined(separator: " "), ascii: ascii)
    }

    /// 小写连续 hex（视图复制时加 `0x` 前缀，与单元格 hex 编辑输入一致）。
    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}