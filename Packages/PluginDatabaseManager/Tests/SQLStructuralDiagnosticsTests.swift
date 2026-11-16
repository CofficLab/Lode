import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-7 结构化 SQL 诊断：括号配对 / 引号与注释闭合 / 形近与不可见字符。
// 范围一律以 UTF-16 码元断言（与编辑器 NSRange 对齐）。

@Suite
struct SQLStructuralDiagnosticsTests {
    private func scan(_ text: String) -> [SQLStructuralDiagnostic] {
        SQLStructuralDiagnostics.scan(text)
    }

    // MARK: - 干净文本

    @Test func emptyTextHasNoDiagnostics() {
        #expect(scan("").isEmpty)
    }

    @Test func balancedSelectHasNoDiagnostics() {
        #expect(scan("SELECT (a + b) * c FROM t WHERE x IN (1, 2);").isEmpty)
    }

    @Test func nestedBalancedBracketsHaveNoDiagnostics() {
        #expect(scan("SELECT f(g(h(x))) FROM t;").isEmpty)
    }

    @Test func squareAndCurlyBracketsPairIndependently() {
        #expect(scan("SELECT [a], {b} FROM t;").isEmpty)
    }

    // MARK: - 括号配对

    @Test func unmatchedOpeningBracketIsError() {
        let text = "SELECT (a FROM t;"
        let diagnostics = scan(text)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].kind == .unmatchedOpeningBracket)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].range == NSRange(location: 7, length: 1))
    }

    @Test func unexpectedClosingBracketIsError() {
        let text = "SELECT a) FROM t;"
        let diagnostics = scan(text)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].kind == .unexpectedClosingBracket)
        #expect(diagnostics[0].range == NSRange(location: 8, length: 1))
    }

    @Test func mismatchedBracketTypesReportAtCloser() {
        let diagnostics = "SELECT (a] FROM t;"
        let result = scan(diagnostics)
        #expect(result.count == 1)
        #expect(result[0].kind == .unexpectedClosingBracket)
        #expect(result[0].range.location == 9)
    }

    @Test func multipleUnmatchedBracketsReportEach() {
        let result = scan("SELECT ((a) FROM t;")
        #expect(result.count == 1)
        #expect(result[0].range.location == 7)
    }

    // MARK: - 字面量与注释屏蔽

    @Test func bracketsInsideSingleQuotedStringIgnored() {
        #expect(scan("SELECT '(' FROM t;").isEmpty)
    }

    @Test func bracketsInsideDoubleQuotedIdentifierIgnored() {
        #expect(scan("SELECT \"(\" FROM t;").isEmpty)
    }

    @Test func bracketsInsideBacktickIdentifierIgnored() {
        #expect(scan("SELECT `(` FROM t;").isEmpty)
    }

    @Test func bracketsInsideLineCommentIgnored() {
        #expect(scan("SELECT 1; -- (").isEmpty)
    }

    @Test func bracketsInsideHashCommentIgnored() {
        #expect(scan("SELECT 1; # (").isEmpty)
    }

    @Test func bracketsInsideBlockCommentIgnored() {
        #expect(scan("SELECT /* ( */ 1;").isEmpty)
    }

    @Test func doubledQuoteEscapeStaysInString() {
        #expect(scan("SELECT 'it''s (' FROM t;").isEmpty)
    }

    @Test func backslashEscapeStaysInString() {
        #expect(scan("SELECT 'a\\'(' FROM t;").isEmpty)
    }

    @Test func doubledDoubleQuoteEscapeStaysInIdentifier() {
        #expect(scan("SELECT \"a\"\"(\" FROM t;").isEmpty)
    }

    @Test func lineCommentEndsAtCRLF() {
        #expect(scan("-- (\r\nSELECT 1;").isEmpty)
    }

    @Test func nestedBlockCommentsCloseTogether() {
        #expect(scan("/* outer /* inner ( */ still comment */ SELECT 1;").isEmpty)
    }

    // MARK: - 未闭合

    @Test func unterminatedSingleQuoteSpansToEOF() {
        let text = "SELECT 'abc"
        let result = scan(text)
        #expect(result.count == 1)
        #expect(result[0].kind == .unterminatedString)
        #expect(result[0].severity == .error)
        #expect(result[0].range == NSRange(location: 7, length: 4))
    }

    @Test func unterminatedDoubleQuoteIsError() {
        let result = scan("SELECT \"abc")
        #expect(result.count == 1)
        #expect(result[0].kind == .unterminatedString)
    }

    @Test func unterminatedBacktickIsError() {
        let result = scan("SELECT `abc")
        #expect(result.count == 1)
        #expect(result[0].kind == .unterminatedString)
    }

    @Test func unterminatedBlockCommentIsError() {
        let text = "SELECT 1; /* ("
        let result = scan(text)
        #expect(result.count == 1)
        #expect(result[0].kind == .unterminatedComment)
        #expect(result[0].range.location == 10)
    }

    @Test func nestedBlockCommentMissingOuterCloseIsError() {
        let result = scan("/* /* inner */")
        #expect(result.count == 1)
        #expect(result[0].kind == .unterminatedComment)
    }

    @Test func unterminatedStringSwallowsFollowingBrackets() {
        let result = scan("SELECT 'abc (def)")
        #expect(result.count == 1)
        #expect(result[0].kind == .unterminatedString)
    }

    // MARK: - 美元引用（PostgreSQL）

    @Test func dollarQuotedBodyIgnoresBrackets() {
        #expect(scan("SELECT $$ ( $$ FROM t;").isEmpty)
    }

    @Test func taggedDollarQuoteIgnoresBrackets() {
        #expect(scan("SELECT $tag$ ( $tag$ FROM t;").isEmpty)
    }

    @Test func mismatchedDollarTagDoesNotCloseLiteral() {
        let result = scan("SELECT $a$ ( $b$")
        #expect(result.count == 1)
        #expect(result[0].kind == .unterminatedString)
    }

    @Test func unterminatedDollarQuoteIsError() {
        let result = scan("SELECT $$ (")
        #expect(result.count == 1)
        #expect(result[0].kind == .unterminatedString)
        #expect(result[0].range.location == 7)
    }

    @Test func positionalParameterIsNotDollarQuote() {
        #expect(scan("SELECT $1 FROM t;").isEmpty)
    }

    // MARK: - 形近字符

    @Test func cyrillicLookalikeOutsideStringIsWarning() {
        let text = "SELECT а FROM t;"
        let result = scan(text)
        #expect(result.count == 1)
        #expect(result[0].kind == .confusableCharacter(ascii: "a"))
        #expect(result[0].severity == .warning)
        #expect(result[0].range == NSRange(location: 7, length: 1))
    }

    @Test func uppercaseCyrillicLookalikeIsWarning() {
        let result = scan("SELECT С FROM t;")
        #expect(result.count == 1)
        #expect(result[0].kind == .confusableCharacter(ascii: "C"))
    }

    @Test func greekOmicronIsWarning() {
        let result = scan("SELECT ο FROM t;")
        #expect(result.count == 1)
        #expect(result[0].kind == .confusableCharacter(ascii: "o"))
    }

    @Test func lookalikeInsideStringIsNotFlagged() {
        #expect(scan("SELECT 'а' FROM t;").isEmpty)
    }

    @Test func lookalikeInsideCommentIsNotFlagged() {
        #expect(scan("SELECT 1; -- а").isEmpty)
    }

    @Test func asciiTextHasNoConfusableWarnings() {
        #expect(scan("SELECT a, e, o, p, c FROM t;").isEmpty)
    }

    // MARK: - 不可见字符

    @Test func zeroWidthSpaceIsWarning() {
        let result = scan("SELECT\u{200B} 1;")
        #expect(result.count == 1)
        #expect(result[0].kind == .invisibleCharacter)
        #expect(result[0].severity == .warning)
        #expect(result[0].range == NSRange(location: 6, length: 1))
    }

    @Test func nonBreakingSpaceIsWarning() {
        let result = scan("SELECT\u{00A0}1;")
        #expect(result.count == 1)
        #expect(result[0].kind == .invisibleCharacter)
    }

    @Test func bomIsWarning() {
        let result = scan("\u{FEFF}SELECT 1;")
        #expect(result.count == 1)
        #expect(result[0].kind == .invisibleCharacter)
        #expect(result[0].range.location == 0)
    }

    @Test func invisibleInsideStringIsNotFlagged() {
        #expect(scan("SELECT 'a\u{00A0}b' FROM t;").isEmpty)
    }

    // MARK: - UTF-16 偏移

    @Test func bracketOffsetCountsSurrogatePairs() {
        let text = "SELECT '😀', ("
        let result = scan(text)
        #expect(result.count == 1)
        #expect(result[0].kind == .unmatchedOpeningBracket)
        // "SELECT '😀', (" → 😀 占 2 个 UTF-16 码元，'(' 位于 13。
        #expect(result[0].range.location == (text as NSString).length - 1)
    }

    @Test func confusableOffsetAfterEmoji() {
        let text = "SELECT '😀', а"
        let result = scan(text)
        #expect(result.count == 1)
        #expect(result[0].range.location == (text as NSString).length - 1)
    }

    @Test func multilineUnterminatedStringRangeSpansLines() {
        let text = "SELECT 'abc\ndef"
        let result = scan(text)
        #expect(result.count == 1)
        #expect(result[0].range == NSRange(location: 7, length: (text as NSString).length - 7))
    }

    // MARK: - 排序与截断

    @Test func resultsAreSortedByLocation() {
        let text = "SELECT а FROM t WHERE (x = 1;"
        let result = scan(text)
        #expect(result.count == 2)
        #expect(result[0].range.location < result[1].range.location)
        #expect(result[0].kind == .confusableCharacter(ascii: "a"))
        #expect(result[1].kind == .unmatchedOpeningBracket)
    }

    @Test func diagnosticsAreCappedAtMaximumCount() {
        let text = String(repeating: "\u{200B}", count: SQLStructuralDiagnostics.maximumCount + 50)
        let result = scan(text)
        #expect(result.count == SQLStructuralDiagnostics.maximumCount)
    }
}