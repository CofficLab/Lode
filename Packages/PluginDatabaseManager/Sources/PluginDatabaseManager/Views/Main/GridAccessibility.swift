import Foundation

/// 网格 VoiceOver 标签助手：单元格读作「列名: 值」，长值截断避免朗读失控。
enum GridAccessibility {
    /// 单个单元格值的朗读上限（字符数）；超出截断并加省略号。
    static let maxValueLength = 200

    static func cellLabel(column: String, value: String) -> String {
        let spoken = value.count > maxValueLength
            ? String(value.prefix(maxValueLength)) + "…"
            : value
        return "\(column): \(spoken)"
    }
}