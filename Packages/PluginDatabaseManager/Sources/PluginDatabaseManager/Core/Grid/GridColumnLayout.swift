import Foundation
import CoreGraphics

/// 网格列布局纯函数核心：列宽估算（有界采样）、显示顺序映射、宽度钳制、
/// 列移动与持久化模型。所有函数无副作用，便于单元测试与百万行性能保证。
public enum GridColumnLayout {
    public static let minWidth: CGFloat = 80
    public static let maxWidth: CGFloat = 320
    public static let defaultSampleLimit = 50
    public static let approxCharWidth: CGFloat = 8
    /// 列宽估算的额外 padding 余量。
    public static let widthPadding: CGFloat = 24

    /// 持久化的列布局：用户调整过的列宽与列顺序。
    public struct Saved: Codable, Equatable, Sendable {
        public var widths: [String: CGFloat]
        public var order: [String]

        public init(widths: [String: CGFloat] = [:], order: [String] = []) {
            self.widths = widths
            self.order = order
        }
    }

    /// 显示顺序 → 数据列索引映射。
    /// order 中的未知列名忽略；结果中未出现在 order 的新列追加到末尾，
    /// 保证自定义 SQL 改变列集时不会丢列。nil/空 order → 自然顺序。
    public static func orderedIndices(columns: [String], order: [String]?) -> [Int] {
        guard let order, !order.isEmpty else { return Array(columns.indices) }
        var seen = Set<Int>()
        var ordered: [Int] = []
        for name in order {
            if let index = columns.firstIndex(of: name), !seen.contains(index) {
                ordered.append(index)
                seen.insert(index)
            }
        }
        for index in columns.indices where !seen.contains(index) {
            ordered.append(index)
        }
        return ordered
    }

    /// 钳制列宽到上下限。
    public static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }

    /// 按列名 + 前 sampleLimit 行内容估算列宽。
    /// 仅采样前若干行，使百万行表的布局计算保持 O(sample) 而非 O(rows)。
    public static func estimateWidths(
        columns: [String],
        rows: [[DatabaseValue]],
        sampleLimit: Int = defaultSampleLimit,
        text: (DatabaseValue) -> String
    ) -> [CGFloat] {
        let sample = min(sampleLimit, rows.count)
        return columns.indices.map { col in
            var maxChars = columns[col].count
            for r in 0..<sample {
                guard col < rows[r].count else { continue }
                maxChars = max(maxChars, text(rows[r][col]).count)
            }
            return clampWidth(CGFloat(maxChars) * approxCharWidth + widthPadding)
        }
    }

    /// 将某列左/右移一位；边界处为无操作。返回基于当前显示顺序的新列名序列。
    public static func moved(columns: [String], order: [String]?, column: String, left: Bool) -> [String] {
        var current = orderedIndices(columns: columns, order: order).map { columns[$0] }
        guard let index = current.firstIndex(of: column) else { return current }
        let target = left ? index - 1 : index + 1
        guard target >= 0, target < current.count else { return current }
        current.swapAt(index, target)
        return current
    }
}