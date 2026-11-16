import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-1 schema 感知补全引擎：上下文解析、关键字/表/列/限定名/别名候选、大小写跟随、排序与截断。
@Suite
struct SQLCompletionEngineTests {
    private func metadata() -> SQLCompletionMetadata {
        SQLCompletionMetadata(
            tables: [
                SQLCompletionTable(name: "users", schema: "public", columns: [
                    SQLCompletionColumn(name: "id", dataType: "integer", isPrimaryKey: true),
                    SQLCompletionColumn(name: "name", dataType: "text"),
                    SQLCompletionColumn(name: "email", dataType: "text")
                ]),
                SQLCompletionTable(name: "orders", schema: "public", columns: [
                    SQLCompletionColumn(name: "id", dataType: "integer", isPrimaryKey: true),
                    SQLCompletionColumn(name: "user_id", dataType: "integer"),
                    SQLCompletionColumn(name: "total", dataType: "numeric")
                ])
            ],
            schemas: ["public", "analytics"]
        )
    }

    private func labels(_ c: [SQLCompletionCandidate]) -> [String] { c.map(\.label) }

    @Test func contextParsesPrefixAndQualifier() {
        let text = "SELECT u.na"
        let ctx = SQLCompletionEngine.context(in: text, utf16Offset: (text as NSString).length)
        #expect(ctx.prefix == "na")
        #expect(ctx.qualifier == "u")
        #expect(ctx.schemaQualifier == nil)
        #expect(ctx.replacementRange == NSRange(location: 9, length: 2))
    }

    @Test func contextEmptyPrefixAfterDot() {
        let text = "SELECT u."
        let ctx = SQLCompletionEngine.context(in: text, utf16Offset: (text as NSString).length)
        #expect(ctx.prefix == "")
        #expect(ctx.qualifier == "u")
        #expect(ctx.replacementRange.length == 0)
    }

    @Test func contextSchemaQualified() {
        let text = "SELECT public.users."
        let ctx = SQLCompletionEngine.context(in: text, utf16Offset: (text as NSString).length)
        #expect(ctx.qualifier == "users")
        #expect(ctx.schemaQualifier == "public")
    }

    @Test func contextHandlesUTF16Surrogates() {
        let text = "SELECT 🎉u."
        let ctx = SQLCompletionEngine.context(in: text, utf16Offset: (text as NSString).length)
        #expect(ctx.prefix == "")
        #expect(ctx.qualifier == "u")
    }

    @Test func keywordCompletionAtStart() {
        let c = SQLCompletionEngine.candidates(in: "SEL", utf16Offset: 3, metadata: metadata(), dialect: .postgresql)
        #expect(labels(c).contains("SELECT"))
        #expect(c.first(where: { $0.label == "SELECT" })?.kind == .keyword)
    }

    @Test func tableCompletionAfterFrom() {
        let text = "SELECT * FROM us"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: (text as NSString).length, metadata: metadata(), dialect: .postgresql)
        #expect(c.first?.label == "users")
        #expect(c.first?.kind == .table)
    }

    @Test func qualifiedColumnViaAlias() {
        let text = "SELECT u. FROM users u"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 9, metadata: metadata(), dialect: .postgresql)
        #expect(Set(labels(c)) == Set(["id", "name", "email"]))
        #expect(c.allSatisfy { $0.kind == .column })
    }

    @Test func qualifiedColumnViaAliasWithAs() {
        let text = "SELECT u. FROM users AS u"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 9, metadata: metadata(), dialect: .postgresql)
        #expect(Set(labels(c)) == Set(["id", "name", "email"]))
    }

    @Test func qualifiedColumnViaTableName() {
        let text = "SELECT users. FROM users"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 13, metadata: metadata(), dialect: .postgresql)
        #expect(Set(labels(c)) == Set(["id", "name", "email"]))
    }

    @Test func schemaQualifiedColumns() {
        let text = "SELECT public.users. FROM public.users"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 20, metadata: metadata(), dialect: .postgresql)
        #expect(Set(labels(c)) == Set(["id", "name", "email"]))
    }

    @Test func schemaCompletionListsTables() {
        let text = "SELECT * FROM public."
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: (text as NSString).length, metadata: metadata(), dialect: .postgresql)
        #expect(Set(labels(c)) == Set(["users", "orders"]))
        #expect(c.allSatisfy { $0.kind == .table })
    }

    @Test func qualifiedPrefixFiltersColumns() {
        let text = "SELECT u.em FROM users u"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 11, metadata: metadata(), dialect: .postgresql)
        #expect(labels(c) == ["email"])
    }

    @Test func unknownQualifierReturnsEmpty() {
        let text = "SELECT x. FROM users"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 9, metadata: metadata(), dialect: .postgresql)
        #expect(c.isEmpty)
    }

    @Test func columnContextBoostsColumns() {
        let text = "SELECT  FROM users"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 7, metadata: metadata(), dialect: .postgresql)
        #expect(c.first?.kind == .column)
    }

    @Test func wherePrefixFiltersColumns() {
        let text = "SELECT * FROM users WHERE em"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: (text as NSString).length, metadata: metadata(), dialect: .postgresql)
        #expect(labels(c).contains("email"))
        #expect(!labels(c).contains("id"))
    }

    @Test func caseFollowsLowercasePrefix() {
        let text = "SELECT * FROM us"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: (text as NSString).length, metadata: metadata(), dialect: .postgresql)
        #expect(c.first?.insertText == "users")
    }

    @Test func caseFollowsUppercasePrefix() {
        let text = "SELECT * FROM US"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: (text as NSString).length, metadata: metadata(), dialect: .postgresql)
        #expect(c.first?.insertText == "USERS")
    }

    @Test func offsetClampsBeyondLength() {
        let c = SQLCompletionEngine.candidates(in: "SEL", utf16Offset: 999, metadata: metadata(), dialect: .postgresql)
        #expect(labels(c).contains("SELECT"))
    }

    @Test func limitTruncatesResults() {
        let c = SQLCompletionEngine.candidates(in: "", utf16Offset: 0, metadata: metadata(), dialect: .postgresql, limit: 3)
        #expect(c.count <= 3)
    }

    @Test func aliasDoesNotSwallowKeyword() {
        // FROM users WHERE … —— WHERE 不能被当成别名。
        let aliases = SQLCompletionEngine.aliasContext(in: "SELECT * FROM users WHERE id = 1")
        #expect(aliases.aliasToTable["where"] == nil)
        #expect(aliases.referenced.contains("users"))
    }

    @Test func joinAliasResolved() {
        let text = "SELECT o. FROM orders o JOIN users u ON o.user_id = u.id"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 9, metadata: metadata(), dialect: .postgresql)
        #expect(Set(labels(c)) == Set(["id", "user_id", "total"]))
    }

    @Test func longTableNameAliasResolved() {
        let md = SQLCompletionMetadata(
            tables: [SQLCompletionTable(name: "comp_pg_users", schema: "public", columns: [
                SQLCompletionColumn(name: "id", dataType: "integer", isPrimaryKey: true),
                SQLCompletionColumn(name: "name", dataType: "text"),
                SQLCompletionColumn(name: "email", dataType: "text")
            ])],
            schemas: ["public", "information_schema", "pg_catalog"]
        )
        let text = "SELECT u. FROM comp_pg_users u"
        let c = SQLCompletionEngine.candidates(in: text, utf16Offset: 9, metadata: md, dialect: .postgresql)
        #expect(Set(labels(c)) == Set(["id", "name", "email"]))
    }
}