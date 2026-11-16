import Foundation

/// 网格选区摘要：选中单元格数量与数值列的 sum/avg。
///
/// 纯逻辑，与渲染层解耦。`value` 提供每个选中位置的当前显示值
/// （含暂存编辑），仅 integer/double 计入数值统计。
public enum GridSelectionSummary {
    public struct Summary: Equatable, Sendable {
        public let cellCount: Int
        public let numericCount: Int
        public let sum: Double

        public init(cellCount: Int, numericCount: Int, sum: Double) {
            self.cellCount = cellCount
            self.numericCount = numericCount
            self.sum = sum
        }

        /// 数值平均值；无数值单元格时为 nil。
        public var average: Double? {
            numericCount > 0 ? sum / Double(numericCount) : nil
        }

        /// 是否含可统计的数值。
        public var hasNumeric: Bool { numericCount > 0 }
    }

    public static func compute(
        positions: Set<GridFind.CellPosition>,
        value: (GridFind.CellPosition) -> DatabaseValue
    ) -> Summary {
        var numericCount = 0
        var sum = 0.0
        for pos in positions {
            switch value(pos) {
            case .integer(let v):
                sum += Double(v)
                numericCount += 1
            case .double(let v):
                sum += v
                numericCount += 1
            default:
                break
            }
        }
        return Summary(cellCount: positions.count, numericCount: numericCount, sum: sum)
    }
}