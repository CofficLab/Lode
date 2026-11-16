@testable import DatabaseManagerPlugin
import Foundation
import Testing

// P3-4 命名参数验收（单元层）：
// - 提取器边界：字符串/带引号标识符/注释内的冒号不算参数；:: 转换不算；重复参数按出现顺序；
// - 改写：MySQL/SQLite 占位符 ? 与 PG $n 按出现顺序，重复名复用值；无参数原样返回；
// - 绑定值：缺值拦截判定、NULL 优先、各类型解析与非法输入。

@Suite
struct SQLNamedParametersTests {
    @Test("基本提取与去重顺序")
    func basicExtraction() {
        let sql = "SELECT * FROM t WHERE a = :id AND b = :name OR c = :id"
        let occ = SQLNamedParameters.occurrences(in: sql)
        #expect(occ.map(\.name) == ["id", "name", "id"])
        #expect(SQLNamedParameters.names(in: sql) == ["id", "name"])
    }

    @Test("字符串字面量内的冒号不提取")
    func colonInsideStringLiteral() {
        let sql = "SELECT ':notparam' AS s, 'a:b' AS t FROM x WHERE id = :real"
        #expect(SQLNamedParameters.names(in: sql) == ["real"])
    }

    @Test("带引号标识符内的冒号不提取")
    func colonInsideQuotedIdentifier() {
        let sql = "SELECT \"col:name\", `back:tick` FROM t WHERE x = :p"
        #expect(SQLNamedParameters.names(in: sql) == ["p"])
    }

    @Test("行注释与块注释内的冒号不提取")
    func colonInsideComments() {
        let sql = """
        SELECT a -- :lineparam
        FROM t /* :blockparam /* :nested */ */ WHERE x = :real
        """
        #expect(SQLNamedParameters.names(in: sql) == ["real"])
    }

    @Test(":: 类型转换不算参数")
    func castIsNotParameter() {
        let sql = "SELECT a::int, b::text FROM t WHERE id = :id"
        #expect(SQLNamedParameters.names(in: sql) == ["id"])
    }

    @Test("转义引号后的参数仍被提取")
    func escapedQuoteThenParameter() {
        let sql = "SELECT 'it''s :fake' AS s WHERE x = :real"
        #expect(SQLNamedParameters.names(in: sql) == ["real"])
    }

    @Test("参数名可含数字/下划线/$，须以字母或下划线开头")
    func parameterNameCharacters() {
        let sql = "SELECT :_a, :b2, :c$d, :1bad, :2 FROM t"
        // :1bad / :2 以数字开头，不算参数。
        #expect(SQLNamedParameters.names(in: sql) == ["_a", "b2", "c$d"])
    }

    @Test("空文本与无参数文本")
    func emptyAndNoParameters() {
        #expect(SQLNamedParameters.occurrences(in: "").isEmpty)
        #expect(SQLNamedParameters.names(in: "SELECT 1").isEmpty)
        #expect(SQLNamedParameters.names(in: "SELECT a:2 FROM t").isEmpty) // 数字开头
    }

    @Test("UTF-16 范围正确（含多字节字符）")
    func occurrenceRanges() {
        let sql = "SELECT '日本' AS s WHERE x = :id"
        let occ = SQLNamedParameters.occurrences(in: sql)
        #expect(occ.count == 1)
        let ns = sql as NSString
        #expect(ns.substring(with: occ[0].range) == ":id")
    }

    @Test("改写为 ? 占位符（MySQL/SQLite），重复名复用值、按出现顺序")
    func rewriteQuestionMark() {
        let sql = "SELECT * FROM t WHERE a = :id AND b = :name OR c = :id"
        let values: [String: DatabaseValue] = ["id": .integer(7), "name": .string("bob")]
        let out = SQLNamedParameters.rewrite(sql, placeholder: { _ in "?" }) { values[$0]! }
        #expect(out.sql == "SELECT * FROM t WHERE a = ? AND b = ? OR c = ?")
        #expect(out.params == [.integer(7), .string("bob"), .integer(7)])
    }

    @Test("改写为 $n 占位符（PostgreSQL），按出现顺序编号")
    func rewriteDollar() {
        let sql = "SELECT * FROM t WHERE a = :id AND b = :name OR c = :id"
        let values: [String: DatabaseValue] = ["id": .integer(7), "name": .string("bob")]
        let out = SQLNamedParameters.rewrite(sql, placeholder: { "$\($0 + 1)" }) { values[$0]! }
        #expect(out.sql == "SELECT * FROM t WHERE a = $1 AND b = $2 OR c = $3")
        #expect(out.params == [.integer(7), .string("bob"), .integer(7)])
    }

    @Test("无参数时原样返回、绑定数组为空")
    func rewriteNoParameters() {
        let sql = "SELECT 1"
        let out = SQLNamedParameters.rewrite(sql, placeholder: { _ in "?" }) { _ in .null }
        #expect(out.sql == sql)
        #expect(out.params.isEmpty)
    }

    @Test("改写保留字符串/注释内的冒号原样")
    func rewritePreservesNonParameters() {
        let sql = "SELECT ':fake' AS s /* :nope */ WHERE x = :real"
        let out = SQLNamedParameters.rewrite(sql, placeholder: { _ in "?" }) { _ in .integer(1) }
        #expect(out.sql == "SELECT ':fake' AS s /* :nope */ WHERE x = ?")
        #expect(out.params == [.integer(1)])
    }
}

@Suite
struct QueryParameterBindingTests {
    @Test("缺值判定：空文本缺值，NULL 与非空文本已提供")
    func satisfaction() {
        #expect(!QueryParameterBinding().isSatisfied)
        #expect(!QueryParameterBinding(kind: .text, text: "").isSatisfied)
        #expect(QueryParameterBinding(kind: .text, text: "x").isSatisfied)
        #expect(QueryParameterBinding(kind: .integer, text: "", isNull: true).isSatisfied)
    }

    @Test("NULL 优先于文本输入")
    func nullPrecedence() {
        let b = QueryParameterBinding(kind: .integer, text: "42", isNull: true)
        #expect(b.databaseValue == .null)
    }

    @Test("text 按原样绑定（保留空白）")
    func textValue() {
        #expect(QueryParameterBinding(kind: .text, text: "  hi  ").databaseValue == .string("  hi  "))
        #expect(QueryParameterBinding(kind: .text, text: "").databaseValue == nil)
    }

    @Test("integer 解析与非法输入")
    func integerValue() {
        #expect(QueryParameterBinding(kind: .integer, text: "42").databaseValue == .integer(42))
        #expect(QueryParameterBinding(kind: .integer, text: " -7 ").databaseValue == .integer(-7))
        #expect(QueryParameterBinding(kind: .integer, text: "3.5").databaseValue == nil)
        #expect(QueryParameterBinding(kind: .integer, text: "abc").databaseValue == nil)
    }

    @Test("real 解析与非法输入")
    func realValue() {
        #expect(QueryParameterBinding(kind: .real, text: "3.5").databaseValue == .double(3.5))
        #expect(QueryParameterBinding(kind: .real, text: "1e3").databaseValue == .double(1000))
        #expect(QueryParameterBinding(kind: .real, text: "abc").databaseValue == nil)
    }

    @Test("boolean 解析多种写法与非法输入")
    func booleanValue() {
        for truthy in ["true", "TRUE", "t", "yes", "y", "1"] {
            #expect(QueryParameterBinding(kind: .boolean, text: truthy).databaseValue == .bool(true))
        }
        for falsy in ["false", "FALSE", "f", "no", "n", "0"] {
            #expect(QueryParameterBinding(kind: .boolean, text: falsy).databaseValue == .bool(false))
        }
        #expect(QueryParameterBinding(kind: .boolean, text: "maybe").databaseValue == nil)
    }
}