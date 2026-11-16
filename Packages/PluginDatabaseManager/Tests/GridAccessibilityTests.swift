import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P6-6a 离线单测：网格 VoiceOver 单元格标签助手（列名前缀 + 长值截断）。

@Suite(.serialized)
struct GridAccessibilityTests {
    @Test func cellLabelPrefixesColumnName() {
        #expect(GridAccessibility.cellLabel(column: "name", value: "Alice") == "name: Alice")
    }

    @Test func cellLabelKeepsEmptyAndNullText() {
        #expect(GridAccessibility.cellLabel(column: "note", value: "") == "note: ")
        #expect(GridAccessibility.cellLabel(column: "note", value: "NULL") == "note: NULL")
    }

    @Test func cellLabelTruncatesLongValues() {
        let long = String(repeating: "x", count: GridAccessibility.maxValueLength + 50)
        let label = GridAccessibility.cellLabel(column: "blob", value: long)
        #expect(label == "blob: " + String(repeating: "x", count: GridAccessibility.maxValueLength) + "…")
    }

    @Test func cellLabelBoundaryIsNotTruncated() {
        let exact = String(repeating: "y", count: GridAccessibility.maxValueLength)
        #expect(GridAccessibility.cellLabel(column: "c", value: exact) == "c: " + exact)
    }

    @Test func cellLabelCountsCharactersNotBytes() {
        let emoji = String(repeating: "🎉", count: GridAccessibility.maxValueLength)
        #expect(GridAccessibility.cellLabel(column: "e", value: emoji) == "e: " + emoji)
    }
}