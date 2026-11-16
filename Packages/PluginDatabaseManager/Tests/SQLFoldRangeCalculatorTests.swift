import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-5 折叠区间正确性：语句/圆括号(CTE)/BEGIN…END/块注释四类多行块，
// 尊重字符串与注释，单行块不折叠，标识符不被误判为关键字。

@Suite struct SQLFoldRangeCalculatorTests {
    private func ranges(_ sql: String, kind: SQLFoldRangeCalculator.Kind) -> [NSRange] {
        SQLFoldRangeCalculator.foldRanges(in: sql).filter { $0.kind == kind }.map(\.range)
    }

    @Test("空文本与单行语句不产生折叠")
    func emptyAndSingleLine() {
        #expect(SQLFoldRangeCalculator.foldRanges(in: "").isEmpty)
        #expect(SQLFoldRangeCalculator.foldRanges(in: "SELECT 1").isEmpty)
        #expect(SQLFoldRangeCalculator.foldRanges(in: "SELECT (1)").isEmpty) // 单行圆括号
    }

    @Test("多行语句产生语句折叠")
    func multiLineStatement() {
        let sql = "SELECT a\nFROM t"
        let statements = ranges(sql, kind: .statement)
        #expect(statements.count == 1)
        #expect(statements.first == NSRange(location: 0, length: (sql as NSString).length))
    }

    @Test("多行圆括号块（含 CTE 体）产生圆括号折叠")
    func multiLineParenthesis() {
        let sql = "SELECT (\n 1\n)"
        let parens = ranges(sql, kind: .parenthesis)
        #expect(parens.count == 1)
        // '(' 在 UTF-16 偏移 7，')' 在 12，范围含两端共 6 个码元。
        #expect(parens.first == NSRange(location: 7, length: 6))
    }

    @Test("CTE 的 AS (...) 体被折叠")
    func cteBody() {
        let sql = "WITH c AS (\n SELECT 1\n)\nSELECT * FROM c"
        let parens = ranges(sql, kind: .parenthesis)
        #expect(parens.count == 1)
        let ns = sql as NSString
        let open = ns.range(of: "(").location
        let close = ns.range(of: ")").location
        #expect(parens.first == NSRange(location: open, length: close - open + 1))
    }

    @Test("嵌套圆括号各自折叠")
    func nestedParentheses() {
        let sql = "(\n(\n1\n)\n)"
        #expect(ranges(sql, kind: .parenthesis).count == 2)
    }

    @Test("多行 BEGIN…END 块折叠（大小写不敏感）")
    func beginEndBlock() {
        let sql = "BEGIN\n SELECT 1;\nEND"
        let blocks = ranges(sql, kind: .beginEnd)
        #expect(blocks.count == 1)
        #expect(blocks.first?.location == 0)
        #expect(blocks.first?.length == (sql as NSString).length)

        let mixed = "begin\n SELECT 1;\nEnd"
        #expect(ranges(mixed, kind: .beginEnd).count == 1)
    }

    @Test("以 END 结尾（无尾随字符）也能配对")
    func trailingEnd() {
        let sql = "BEGIN\n SELECT 1;\nEND"
        #expect(ranges(sql, kind: .beginEnd).count == 1)
    }

    @Test("标识符 END2 / _END 不被误判为关键字")
    func identifierNotKeyword() {
        #expect(ranges("BEGIN\n END2\n", kind: .beginEnd).isEmpty)
        #expect(ranges("BEGIN\n xEND\n", kind: .beginEnd).isEmpty)
    }

    @Test("多行块注释折叠")
    func multiLineBlockComment() {
        let sql = "/* a\nb */ SELECT 1"
        let comments = ranges(sql, kind: .blockComment)
        #expect(comments.count == 1)
        #expect(comments.first == NSRange(location: 0, length: 9))
    }

    @Test("字符串内的括号与关键字不产生块折叠")
    func literalsIgnored() {
        let sql = "SELECT '(\n)' AS x"
        #expect(ranges(sql, kind: .parenthesis).isEmpty)
        #expect(ranges(sql, kind: .beginEnd).isEmpty)
        // 行注释里的 BEGIN 也不配对。
        let commented = "SELECT 1 -- BEGIN\n FROM t"
        #expect(ranges(commented, kind: .beginEnd).isEmpty)
    }

    @Test("范围按起点升序、同起点外层在前")
    func sortedOuterFirst() {
        let sql = "SELECT (\n 1\n)"
        let all = SQLFoldRangeCalculator.foldRanges(in: sql)
        #expect(all.count == 2)
        #expect(all[0].kind == .statement) // 起点 0，外层
        #expect(all[1].kind == .parenthesis) // 起点 7
        #expect(all[0].range.location <= all[1].range.location)
    }

    @Test("多字节字符下 UTF-16 范围正确")
    func utf16Ranges() {
        let sql = "SELECT '日本' AS x,\n (\n 1\n)"
        let parens = ranges(sql, kind: .parenthesis)
        #expect(parens.count == 1)
        let ns = sql as NSString
        let open = ns.range(of: "(").location
        let close = ns.range(of: ")").location
        #expect(parens.first == NSRange(location: open, length: close - open + 1))
    }
}

@Suite struct EditorDocumentGuardTests {
    private let threshold = EditorDocumentGuard.largeDocumentUTF16Threshold

    @Test("阈值为 2M UTF-16")
    func thresholdValue() {
        #expect(threshold == 2_000_000)
    }

    @Test("低于阈值全功能开启、不提示")
    func belowThreshold() {
        for length in [0, 1, threshold - 1] {
            let decision = EditorDocumentGuard.evaluate(utf16Length: length)
            #expect(decision.highlightEnabled)
            #expect(decision.foldEnabled)
            #expect(decision.parseEnabled)
            #expect(decision.showNotice == false)
        }
    }

    @Test("达到/超过阈值关闭高亮/折叠/解析并提示")
    func atAndAboveThreshold() {
        for length in [threshold, threshold + 1, threshold * 2] {
            let decision = EditorDocumentGuard.evaluate(utf16Length: length)
            #expect(decision.highlightEnabled == false)
            #expect(decision.foldEnabled == false)
            #expect(decision.parseEnabled == false)
            #expect(decision.showNotice)
        }
    }

    @Test("isLargeDocument 按 UTF-16 而非字符数判定")
    func utf16NotCharacterCount() {
        #expect(EditorDocumentGuard.isLargeDocument(String(repeating: "a", count: threshold - 1)) == false)
        #expect(EditorDocumentGuard.isLargeDocument(String(repeating: "a", count: threshold)))
        // 每个 emoji 占 2 个 UTF-16 码元：字符数仅阈值一半即触发。
        #expect(EditorDocumentGuard.isLargeDocument(String(repeating: "😀", count: threshold / 2)))
        #expect(EditorDocumentGuard.isLargeDocument(String(repeating: "😀", count: threshold / 2 - 1)) == false)
    }
}