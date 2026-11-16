import Foundation
import CoreGraphics
import Testing
@testable import DatabaseManagerPlugin

// P2-6 列布局核心：显示顺序映射、宽度钳制、有界采样估算、列移动、持久化往返。
@Suite
struct GridColumnLayoutTests {
    @Test func orderedIndicesNaturalWhenNoOrder() {
        #expect(GridColumnLayout.orderedIndices(columns: ["a", "b", "c"], order: nil) == [0, 1, 2])
        #expect(GridColumnLayout.orderedIndices(columns: ["a", "b", "c"], order: []) == [0, 1, 2])
    }

    @Test func orderedIndicesAppliesReorder() {
        #expect(GridColumnLayout.orderedIndices(columns: ["a", "b", "c"], order: ["c", "a", "b"]) == [2, 0, 1])
    }

    @Test func orderedIndicesIgnoresUnknownAndAppendsNewColumns() {
        // "x" 不存在忽略；b 未在 order 中 → 追加末尾
        #expect(GridColumnLayout.orderedIndices(columns: ["a", "b", "c"], order: ["c", "x"]) == [2, 0, 1])
    }

    @Test func orderedIndicesDeduplicates() {
        #expect(GridColumnLayout.orderedIndices(columns: ["a", "b", "c"], order: ["a", "a", "b"]) == [0, 1, 2])
    }

    @Test func clampWidthBoundaries() {
        #expect(GridColumnLayout.clampWidth(10) == GridColumnLayout.minWidth)
        #expect(GridColumnLayout.clampWidth(500) == GridColumnLayout.maxWidth)
        #expect(GridColumnLayout.clampWidth(150) == 150)
    }

    @Test func estimateWidthsSamplesOnlyPrefix() {
        // 前 50 行短内容，其后 1000 行超长内容；有界采样应只看前 50 行。
        var rows: [[DatabaseValue]] = Array(repeating: [.string("x")], count: 50)
        rows.append(contentsOf: Array(repeating: [.string(String(repeating: "y", count: 2000))], count: 1000))
        let widths = GridColumnLayout.estimateWidths(columns: ["v"], rows: rows) { value in
            if case .string(let s) = value { return s } else { return "" }
        }
        // 1 字符 * 8 + 24 = 32 → 钳制到下限 80（若采样全部会得到上限 320）
        #expect(widths == [GridColumnLayout.minWidth])
    }

    @Test func estimateWidthsFallsBackToColumnNameLength() {
        let widths = GridColumnLayout.estimateWidths(columns: ["long_column_name"], rows: []) { _ in "" }
        // 16 字符 * 8 + 24 = 152
        #expect(widths == [152])
    }

    @Test func movedLeftRightBoundaries() {
        let columns = ["a", "b", "c"]
        #expect(GridColumnLayout.moved(columns: columns, order: nil, column: "a", left: true) == ["a", "b", "c"])
        #expect(GridColumnLayout.moved(columns: columns, order: nil, column: "a", left: false) == ["b", "a", "c"])
        #expect(GridColumnLayout.moved(columns: columns, order: nil, column: "c", left: false) == ["a", "b", "c"])
        #expect(GridColumnLayout.moved(columns: columns, order: nil, column: "c", left: true) == ["a", "c", "b"])
    }

    @Test func movedRespectsExistingOrder() {
        let columns = ["a", "b", "c"]
        // 当前显示顺序 c,a,b；把 c 右移 → a,c,b
        #expect(GridColumnLayout.moved(columns: columns, order: ["c", "a", "b"], column: "c", left: false) == ["a", "c", "b"])
    }

    @Test func savedLayoutCodableRoundTrip() throws {
        let saved = GridColumnLayout.Saved(widths: ["id": 120, "name": 200], order: ["name", "id"])
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(GridColumnLayout.Saved.self, from: data)
        #expect(decoded == saved)
    }
}