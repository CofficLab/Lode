import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// P1-5 光标定位：⌘↩ 执行光标所在语句。
///
/// 复用切分器边界，验证引号内分号、行/块注释（含嵌套）、UTF-16 多字节偏移、
/// 末句尾部与间隙等光标落点都能正确归属到可执行语句。
struct StatementAtCursorTests {
    /// 子串在源文本中的 UTF-16 偏移（与编辑器回写的光标偏移同坐标系）。
    private func offset(of substring: String, in sql: String) -> Int {
        (sql as NSString).range(of: substring).location
    }

    @Test("单引号内的分号不作为语句分隔")
    func semicolonInsideSingleQuotes() {
        let sql = "SELECT 'a;b'; SELECT 2;"
        #expect(SQLStatementParser.split(sql) == ["SELECT 'a;b'", "SELECT 2"])
        #expect(SQLStatementParser.statement(atCursor: offset(of: "a;b", in: sql), in: sql) == "SELECT 'a;b'")
        #expect(SQLStatementParser.statement(atCursor: offset(of: "SELECT 2", in: sql), in: sql) == "SELECT 2")
    }

    @Test("双引号标识符内的分号不作为语句分隔")
    func semicolonInsideDoubleQuotes() {
        let sql = "SELECT \"a;b\"; SELECT 2;"
        #expect(SQLStatementParser.split(sql) == ["SELECT \"a;b\"", "SELECT 2"])
        #expect(SQLStatementParser.statement(atCursor: offset(of: "a;b", in: sql), in: sql) == "SELECT \"a;b\"")
    }

    @Test("反引号标识符内的分号不作为语句分隔")
    func semicolonInsideBackticks() {
        let sql = "SELECT `a;b`; SELECT 2;"
        #expect(SQLStatementParser.split(sql) == ["SELECT `a;b`", "SELECT 2"])
        #expect(SQLStatementParser.statement(atCursor: offset(of: "a;b", in: sql), in: sql) == "SELECT `a;b`")
    }

    @Test("行注释内的分号不切分；前导注释归属后续语句")
    func semicolonInsideLineComment() {
        let sql = "SELECT 1; -- comment; here\nSELECT 2;"
        // 注释里的分号没有把脚本切成三段；前导注释与后续语句同属一段。
        #expect(SQLStatementParser.split(sql) == ["SELECT 1", "-- comment; here\nSELECT 2"])
        #expect(SQLStatementParser.statement(atCursor: offset(of: "SELECT 2", in: sql), in: sql) == "-- comment; here\nSELECT 2")
        #expect(SQLStatementParser.statement(atCursor: offset(of: "comment", in: sql), in: sql) == "-- comment; here\nSELECT 2")
    }

    @Test("尾随纯注释是间隙：光标落在其中返回 nil")
    func trailingCommentGap() {
        let sql = "SELECT 1; -- trailing gap"
        #expect(SQLStatementParser.split(sql) == ["SELECT 1"])
        #expect(SQLStatementParser.statement(atCursor: offset(of: "trailing", in: sql), in: sql) == nil)
    }

    @Test("嵌套块注释内的分号与 BEGIN 关键字不切分；前导注释归属后续语句")
    func semicolonInsideNestedBlockComment() {
        let sql = "SELECT 1; /* outer /* inner; BEGIN; */ tail; */ SELECT 2;"
        #expect(SQLStatementParser.split(sql) == ["SELECT 1", "/* outer /* inner; BEGIN; */ tail; */ SELECT 2"])
        #expect(SQLStatementParser.statement(atCursor: offset(of: "SELECT 2", in: sql), in: sql) == "/* outer /* inner; BEGIN; */ tail; */ SELECT 2")
        #expect(SQLStatementParser.statement(atCursor: offset(of: "inner", in: sql), in: sql) == "/* outer /* inner; BEGIN; */ tail; */ SELECT 2")
    }

    @Test("纯注释开头脚本：注释与语句同属一段，光标命中该语句")
    func leadingNestedCommentWithBegin() {
        let sql = "/* BEGIN; nested /* x; */ */ SELECT 1;"
        #expect(SQLStatementParser.split(sql) == ["/* BEGIN; nested /* x; */ */ SELECT 1"])
        #expect(SQLStatementParser.statement(atCursor: offset(of: "BEGIN", in: sql), in: sql) == "/* BEGIN; nested /* x; */ */ SELECT 1")
        #expect(SQLStatementParser.statement(atCursor: offset(of: "SELECT 1", in: sql), in: sql) == "/* BEGIN; nested /* x; */ */ SELECT 1")
    }

    @Test("光标停在末句尾部（无尾分号）仍命中末句")
    func cursorAtEndOfLastStatement() {
        let sql = "SELECT 1; SELECT 2"
        #expect(SQLStatementParser.statement(atCursor: sql.utf16.count, in: sql) == "SELECT 2")
        #expect(SQLStatementParser.statement(atCursor: sql.utf16.count - 1, in: sql) == "SELECT 2")
    }

    @Test("光标落在语句前导空白仍归属该语句")
    func cursorInLeadingWhitespace() {
        let sql = "SELECT 1;\n   SELECT 2;"
        let cursor = offset(of: "SELECT 2", in: sql) - 1
        #expect(SQLStatementParser.statement(atCursor: cursor, in: sql) == "SELECT 2")
    }

    @Test("负偏移返回 nil")
    func negativeCursor() {
        #expect(SQLStatementParser.statement(atCursor: -1, in: "SELECT 1;") == nil)
    }

    @Test("UTF-16 多字节字符前的偏移换算正确")
    func multibyteUTF16Offset() {
        let sql = "SELECT '中文😀'; SELECT 2;"
        #expect(SQLStatementParser.split(sql) == ["SELECT '中文😀'", "SELECT 2"])
        #expect(SQLStatementParser.statement(atCursor: offset(of: "中文", in: sql), in: sql) == "SELECT '中文😀'")
        #expect(SQLStatementParser.statement(atCursor: offset(of: "SELECT 2", in: sql), in: sql) == "SELECT 2")
    }

    @Test("locateStatements 的可执行投影与 split 完全一致")
    func locatedProjectionMatchesSplit() {
        let sql = "SELECT 1; -- c\n/* x; */ SELECT 'a;b'; SELECT 2"
        let located = SQLStatementParser.locateStatements(in: sql)
        #expect(located.filter(\.isExecutable).map(\.text) == SQLStatementParser.split(sql))
        // 每个可执行片段的光标中点都能命中自身。
        for stmt in located where stmt.isExecutable {
            let mid = stmt.range.location + stmt.range.length / 2
            #expect(SQLStatementParser.statement(atCursor: mid, in: sql) == stmt.text)
        }
    }

    @Test("空文本与纯空白返回 nil")
    func emptyText() {
        #expect(SQLStatementParser.statement(atCursor: 0, in: "") == nil)
        #expect(SQLStatementParser.statement(atCursor: 0, in: "   \n  ") == nil)
    }
}