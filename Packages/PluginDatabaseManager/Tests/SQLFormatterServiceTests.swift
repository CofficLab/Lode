@testable import DatabaseManagerPlugin
import Foundation
import Testing

// P3-3 SQL 格式化器验收：
// - 幂等：format(format(x)) == format(x)（多组输入 × 多组配置）；
// - 语义不变：格式化前后 token 流等价（仅空白与关键字大小写变化）；
// - 关键字大小写可配；字面量/带引号标识符/注释内容原样保留；
// - 主要子句换行 + 列表逐项换行 + 子查询缩进。

@Suite
struct SQLFormatterServiceTests {
    /// 把 token 流归一（关键字统一大写）后比较，证明语义不变。
    private func normalizedTokens(_ sql: String) -> [String] {
        SQLFormatterService.tokenize(sql).map { tok in
            if tok.kind == .word && SQLFormatterService.keywords.contains(tok.text.uppercased()) {
                return tok.text.uppercased()
            }
            return tok.text
        }
    }

    private let samples: [String] = [
        "select a,b,c from users where id=1 and name='x' order by a desc limit 10;",
        "SELECT u.id, u.name, COUNT(o.id) AS n FROM users u LEFT JOIN orders o ON o.user_id=u.id WHERE u.active=TRUE GROUP BY u.id, u.name HAVING COUNT(o.id)>2 ORDER BY n DESC;",
        "select * from (select id from t where x>=1) sub where sub.id in (1,2,3);",
        "insert into t (a,b) values (1,'two'),(2,'three');",
        "update t set a=1, b=b+1 where id=5;",
        "delete from t where id=5;",
        "with cte as (select id from t) select * from cte;",
        "SELECT 'hello  world' AS s, \"Mixed Case\", `back tick`, 1.5e-3, 0xFF, :param, ?, $1 FROM t; -- trailing note\n/* block /* nested */ comment */ SELECT 2;",
        "select case when a>1 then 'big' else 'small' end as label from t;",
        "SELECT a::int, b->>'k', c||d FROM t WHERE a BETWEEN 1 AND 10;",
        "",
        "   ",
        "-- only a comment",
        "SELECT 1; SELECT 2; SELECT 3;"
    ]

    @Test("幂等：多次格式化结果稳定")
    func idempotent() {
        let configs: [SQLFormatterOptions] = [
            SQLFormatterOptions(),
            SQLFormatterOptions(keywordCase: .lower),
            SQLFormatterOptions(keywordCase: .preserve),
            SQLFormatterOptions(indentWidth: 4, useTabs: true),
            SQLFormatterOptions(clausePerLine: false, commaNewlineInList: false)
        ]
        for options in configs {
            for sql in samples {
                let once = SQLFormatterService.format(sql, options: options)
                let twice = SQLFormatterService.format(once, options: options)
                #expect(once == twice, "not idempotent for \(sql.prefix(40)) with \(options)")
            }
        }
    }

    @Test("语义不变：格式化前后 token 流等价")
    func semanticsPreserved() {
        for options in [SQLFormatterOptions(), SQLFormatterOptions(keywordCase: .preserve), SQLFormatterOptions(keywordCase: .lower)] {
            for sql in samples {
                let formatted = SQLFormatterService.format(sql, options: options)
                #expect(normalizedTokens(sql) == normalizedTokens(formatted), "tokens changed for \(sql.prefix(40))")
                // 切分器语句数不变。
                #expect(SQLStatementParser.split(sql).count == SQLStatementParser.split(formatted).count)
            }
        }
    }

    @Test("关键字大小写可配，标识符不受影响")
    func keywordCaseConfigurable() {
        let sql = "select myCol from myTable where myCol=1"
        let upper = SQLFormatterService.format(sql, options: SQLFormatterOptions(keywordCase: .upper))
        #expect(upper.contains("SELECT"))
        #expect(upper.contains("FROM"))
        #expect(upper.contains("WHERE"))
        #expect(upper.contains("myCol"))
        #expect(upper.contains("myTable"))

        let lower = SQLFormatterService.format(sql, options: SQLFormatterOptions(keywordCase: .lower))
        #expect(lower.contains("select"))
        #expect(lower.contains("from"))
        #expect(lower.contains("myCol"))

        let preserve = SQLFormatterService.format(sql, options: SQLFormatterOptions(keywordCase: .preserve))
        #expect(preserve.contains("select"))
        #expect(preserve.contains("myCol"))
    }

    @Test("字面量/带引号标识符/注释内容原样保留")
    func literalsAndCommentsPreserved() {
        let sql = "SELECT 'a  b''c', \"Keep  Case\", `x  y`, 1 /* keep  this */ FROM t -- note  here"
        let formatted = SQLFormatterService.format(sql)
        #expect(formatted.contains("'a  b''c'"))
        #expect(formatted.contains("\"Keep  Case\""))
        #expect(formatted.contains("`x  y`"))
        #expect(formatted.contains("/* keep  this */"))
        #expect(formatted.contains("-- note  here"))
    }

    @Test("主要子句换行与列表逐项换行")
    func clauseAndListLayout() {
        let sql = "select a,b from t where x=1 group by a,b order by a desc"
        let formatted = SQLFormatterService.format(sql)
        let lines = formatted.components(separatedBy: "\n")
        #expect(lines.contains("SELECT"))
        #expect(lines.contains("FROM t"))
        #expect(lines.contains("WHERE x = 1"))
        #expect(lines.contains("GROUP BY"))
        #expect(lines.contains("ORDER BY"))
        // SELECT 列表逐项缩进换行。
        #expect(formatted.contains("SELECT\n  a,\n  b"))
        // GROUP BY 列表逐项换行。
        #expect(formatted.contains("GROUP BY\n  a,\n  b"))
    }

    @Test("子查询缩进")
    func subqueryIndentation() {
        let sql = "select * from (select id from t) sub"
        let formatted = SQLFormatterService.format(sql)
        #expect(formatted.contains("FROM (\n  SELECT\n    id\n  FROM t\n) sub"))
    }

    @Test("关闭子句换行时保持单行（仍规范化空白/大小写）")
    func clausePerLineDisabled() {
        let sql = "select a,b from t where x=1"
        let formatted = SQLFormatterService.format(sql, options: SQLFormatterOptions(clausePerLine: false, commaNewlineInList: false))
        #expect(!formatted.contains("\n"))
        #expect(formatted.contains("SELECT"))
        #expect(normalizedTokens(sql) == normalizedTokens(formatted))
    }

    @Test("多语句各自格式化并以分号分隔")
    func multipleStatements() {
        let sql = "select 1;select 2;"
        let formatted = SQLFormatterService.format(sql)
        #expect(SQLStatementParser.split(formatted).count == 2)
        #expect(formatted.contains(";"))
        #expect(normalizedTokens(sql) == normalizedTokens(formatted))
    }
}