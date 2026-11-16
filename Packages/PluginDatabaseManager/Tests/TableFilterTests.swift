import Foundation
import Testing

@testable import DatabaseManagerPlugin

/// P2-1 筛选模型：每运算符 → 参数化 SQL + 注入防护 + 跨引擎方言映射。
@Suite
struct TableFilterTests {
    private func col(_ name: String, _ type: String) -> TableColumn {
        TableColumn(name: name, dataType: type, isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 0)
    }

    private func filter(_ op: FilterOperator, _ operands: [String], column: String = "name", caseSensitive: Bool = false) -> TableFilter {
        TableFilter(conditions: [FilterCondition(column: column, op: op, operands: operands, caseSensitive: caseSensitive)])
    }

    // MARK: - 比较运算符（参数化 + 方言占位符）

    @Test(arguments: [DatabaseType.sqlite, .mysql, .postgresql])
    func comparisonOperatorsAreParameterized(type: DatabaseType) {
        let cases: [(FilterOperator, String)] = [
            (.equals, "="), (.notEquals, "<>"), (.greaterThan, ">"),
            (.greaterOrEqual, ">="), (.lessThan, "<"), (.lessOrEqual, "<="),
        ]
        for (op, sqlOp) in cases {
            let result = filter(op, ["ann"]).buildWhere(dialect: type)
            #expect(result != nil)
            let placeholder = type == .postgresql ? "$1" : "?"
            #expect(result?.clause == "\"name\" \(sqlOp) \(placeholder)" || result?.clause == "`name` \(sqlOp) \(placeholder)")
            #expect(result?.params == [.string("ann")])
        }
    }

    @Test
    func mysqlUsesBacktickIdentifiers() {
        let result = filter(.equals, ["x"]).buildWhere(dialect: .mysql)
        #expect(result?.clause == "`name` = ?")
    }

    @Test
    func postgresUsesNumberedPlaceholders() {
        let f = TableFilter(conditions: [
            FilterCondition(column: "a", op: .equals, operands: ["1"]),
            FilterCondition(column: "b", op: .greaterThan, operands: ["2"]),
        ])
        let result = f.buildWhere(dialect: .postgresql, columns: [col("a", "integer"), col("b", "integer")])
        #expect(result?.clause == "\"a\" = $1 AND \"b\" > $2")
        #expect(result?.params == [.integer(1), .integer(2)])
    }

    // MARK: - 注入防护

    @Test(arguments: [DatabaseType.sqlite, .mysql, .postgresql])
    func injectionAttemptStaysInParameter(type: DatabaseType) {
        let evil = "'; DROP TABLE users; --"
        let result = filter(.equals, [evil]).buildWhere(dialect: type)
        // 恶意文本只出现在参数里，绝不出现在 SQL 子句中。
        #expect(result?.clause.contains("DROP") == false)
        #expect(result?.clause.contains("'") == false)
        #expect(result?.params == [.string(evil)])
    }

    @Test
    func identifierQuoteIsEscaped() {
        let f = TableFilter(conditions: [FilterCondition(column: "we\"ird", op: .isNull)])
        let result = f.buildWhere(dialect: .postgresql)
        #expect(result?.clause == "\"we\"\"ird\" IS NULL")
    }

    // MARK: - 类型感知绑定（PG 数值列比较不报类型错误）

    @Test
    func integerColumnBindsInteger() {
        let result = filter(.greaterThan, ["42"], column: "age").buildWhere(dialect: .postgresql, columns: [col("age", "integer")])
        #expect(result?.params == [.integer(42)])
    }

    @Test
    func realColumnBindsDouble() {
        let result = filter(.lessThan, ["3.5"], column: "score").buildWhere(dialect: .postgresql, columns: [col("score", "double precision")])
        #expect(result?.params == [.double(3.5)])
    }

    @Test
    func booleanColumnBindsBool() {
        let result = filter(.equals, ["true"], column: "active").buildWhere(dialect: .postgresql, columns: [col("active", "boolean")])
        #expect(result?.params == [.bool(true)])
        // MySQL BOOLEAN 即 tinyint(1)，同样按布尔绑定。
        let mysql = filter(.equals, ["false"], column: "active").buildWhere(dialect: .mysql, columns: [col("active", "tinyint(1)")])
        #expect(mysql?.params == [.bool(false)])
    }

    @Test
    func textColumnKeepsStringEvenIfNumeric() {
        let result = filter(.equals, ["123"], column: "code").buildWhere(dialect: .postgresql, columns: [col("code", "varchar(10)")])
        #expect(result?.params == [.string("123")])
    }

    @Test
    func betweenBindsTypedPair() {
        let result = filter(.between, ["10", "20"], column: "age").buildWhere(dialect: .postgresql, columns: [col("age", "integer")])
        #expect(result?.clause == "\"age\" BETWEEN $1 AND $2")
        #expect(result?.params == [.integer(10), .integer(20)])
    }

    // MARK: - LIKE 模式与转义

    @Test
    func containsInsensitiveWrapsLower() {
        let result = filter(.contains, ["ann"]).buildWhere(dialect: .sqlite)
        #expect(result?.clause == "LOWER(\"name\") LIKE LOWER(?) ESCAPE '!'")
        #expect(result?.params == [.string("%ann%")])
    }

    @Test
    func containsSensitiveUsesPlainLike() {
        let result = filter(.contains, ["ann"], caseSensitive: true).buildWhere(dialect: .postgresql)
        #expect(result?.clause == "\"name\" LIKE $1 ESCAPE '!'")
        #expect(result?.params == [.string("%ann%")])
    }

    @Test
    func mysqlSensitiveLikeCastsBinary() {
        // MySQL 默认排序规则大小写不敏感，敏感匹配必须转 BINARY 比较。
        let result = filter(.contains, ["ann"], caseSensitive: true).buildWhere(dialect: .mysql)
        #expect(result?.clause == "CAST(`name` AS BINARY) LIKE ? ESCAPE '!'")
        #expect(result?.params == [.string("%ann%")])
        let negated = filter(.notContains, ["ann"], caseSensitive: true).buildWhere(dialect: .mysql)
        #expect(negated?.clause == "CAST(`name` AS BINARY) NOT LIKE ? ESCAPE '!'")
    }

    @Test
    func sqliteSensitiveLikeUsesGlob() {
        // SQLite LIKE 对 ASCII 大小写不敏感；GLOB 敏感且通配符为 * ?。
        let result = filter(.contains, ["ann"], caseSensitive: true).buildWhere(dialect: .sqlite)
        #expect(result?.clause == "\"name\" GLOB ?")
        #expect(result?.params == [.string("*ann*")])
        #expect(filter(.startsWith, ["ab"], caseSensitive: true).buildWhere(dialect: .sqlite)?.params == [.string("ab*")])
        #expect(filter(.endsWith, ["yz"], caseSensitive: true).buildWhere(dialect: .sqlite)?.params == [.string("*yz")])
    }

    @Test
    func sqliteGlobEscapesSpecialCharacters() {
        // 字面 * ? [ ] 包进括号表达式；LIKE 的 !% !_ !! 还原为字面 % _ !。
        let result = filter(.contains, ["a*b?c[d]e%f_g!"], caseSensitive: true).buildWhere(dialect: .sqlite)
        #expect(result?.params == [.string("*a[*]b[?]c[[]d[]]e%f_g!*")])
    }

    @Test
    func startsAndEndsWithPatterns() {
        #expect(filter(.startsWith, ["ab"]).buildWhere(dialect: .sqlite)?.params == [.string("ab%")])
        #expect(filter(.endsWith, ["yz"]).buildWhere(dialect: .sqlite)?.params == [.string("%yz")])
    }

    @Test
    func notContainsNegates() {
        let result = filter(.notContains, ["x"], caseSensitive: true).buildWhere(dialect: .sqlite)
        #expect(result?.clause == "\"name\" NOT GLOB ?")
        #expect(result?.params == [.string("*x*")])
        let insensitive = filter(.notContains, ["x"]).buildWhere(dialect: .postgresql)
        #expect(insensitive?.clause == "LOWER(\"name\") NOT LIKE LOWER($1) ESCAPE '!'")
    }

    @Test
    func likeWildcardsAreEscaped() {
        let result = filter(.contains, ["100%_!"]).buildWhere(dialect: .sqlite)
        #expect(result?.params == [.string("%100!%!_!!%")])
    }

    // MARK: - 列表与一元运算符

    @Test
    func inListFiltersEmptyOperands() {
        let result = filter(.inList, ["a", "", "b"], column: "tag").buildWhere(dialect: .postgresql, columns: [col("tag", "text")])
        #expect(result?.clause == "\"tag\" IN ($1, $2)")
        #expect(result?.params == [.string("a"), .string("b")])
    }

    @Test
    func notInListNegates() {
        let result = filter(.notInList, ["1", "2"], column: "id").buildWhere(dialect: .sqlite, columns: [col("id", "integer")])
        #expect(result?.clause == "\"id\" NOT IN (?, ?)")
        #expect(result?.params == [.integer(1), .integer(2)])
    }

    @Test(arguments: [FilterOperator.isNull, .isNotNull, .isEmpty, .isNotEmpty])
    func unaryOperatorsHaveNoParams(op: FilterOperator) {
        let result = filter(op, []).buildWhere(dialect: .postgresql)
        #expect(result?.params.isEmpty == true)
        #expect(result?.clause.isEmpty == false)
    }

    @Test
    func nullAndEmptyClauses() {
        #expect(filter(.isNull, []).buildWhere(dialect: .sqlite)?.clause == "\"name\" IS NULL")
        #expect(filter(.isNotNull, []).buildWhere(dialect: .sqlite)?.clause == "\"name\" IS NOT NULL")
        #expect(filter(.isEmpty, []).buildWhere(dialect: .sqlite)?.clause == "\"name\" = ''")
        #expect(filter(.isNotEmpty, []).buildWhere(dialect: .sqlite)?.clause == "\"name\" <> ''")
    }

    // MARK: - REGEX 方言映射

    @Test
    func regexPostgresCaseSensitiveAndInsensitive() {
        #expect(filter(.regex, ["^a"], caseSensitive: true).buildWhere(dialect: .postgresql)?.clause == "\"name\" ~ $1")
        #expect(filter(.regex, ["^a"], caseSensitive: false).buildWhere(dialect: .postgresql)?.clause == "\"name\" ~* $1")
        #expect(filter(.regex, ["^a"]).buildWhere(dialect: .postgresql)?.params == [.string("^a")])
    }

    @Test
    func regexMySQLUsesRegexpLike() {
        #expect(filter(.regex, ["^a"], caseSensitive: true).buildWhere(dialect: .mysql)?.clause == "REGEXP_LIKE(`name`, ?, 'c')")
        #expect(filter(.regex, ["^a"], caseSensitive: false).buildWhere(dialect: .mysql)?.clause == "REGEXP_LIKE(`name`, ?, 'i')")
    }

    @Test
    func regexSQLiteUsesRegexp() {
        let result = filter(.regex, ["^a"]).buildWhere(dialect: .sqlite)
        #expect(result?.clause == "\"name\" REGEXP ?")
        #expect(result?.params == [.string("^a")])
    }

    // MARK: - 组合 / 启用 / 完整性

    @Test
    func multipleConditionsCombineWithAnd() {
        let f = TableFilter(conditions: [
            FilterCondition(column: "a", op: .equals, operands: ["1"]),
            FilterCondition(column: "b", op: .contains, operands: ["x"]),
        ])
        let result = f.buildWhere(dialect: .sqlite, columns: [col("a", "integer"), col("b", "text")])
        #expect(result?.clause == "\"a\" = ? AND LOWER(\"b\") LIKE LOWER(?) ESCAPE '!'")
        #expect(result?.params == [.integer(1), .string("%x%")])
    }

    @Test
    func disabledConditionsAreExcluded() {
        let f = TableFilter(conditions: [
            FilterCondition(column: "a", op: .equals, operands: ["1"], isEnabled: false),
            FilterCondition(column: "b", op: .equals, operands: ["2"]),
        ])
        let result = f.buildWhere(dialect: .sqlite)
        #expect(result?.clause == "\"b\" = ?")
    }

    @Test
    func incompleteConditionsAreExcluded() {
        let f = TableFilter(conditions: [
            FilterCondition(column: "a", op: .equals, operands: [""]),       // 空操作数
            FilterCondition(column: "", op: .isNull),                        // 无列名
            FilterCondition(column: "b", op: .between, operands: ["1"]),     // between 缺第二值
        ])
        #expect(f.buildWhere(dialect: .sqlite) == nil)
        #expect(f.isActive == false)
    }

    @Test
    func emptyFilterProducesNoWhere() {
        #expect(TableFilter.empty.buildWhere(dialect: .sqlite) == nil)
        #expect(TableFilter.empty.isActive == false)
    }

    @Test
    func isCompleteRespectsOperandKind() {
        #expect(FilterCondition(column: "a", op: .isNull).isComplete)
        #expect(!FilterCondition(column: "a", op: .equals, operands: [""]).isComplete)
        #expect(FilterCondition(column: "a", op: .equals, operands: ["x"]).isComplete)
        #expect(!FilterCondition(column: "a", op: .between, operands: ["1", ""]).isComplete)
        #expect(FilterCondition(column: "a", op: .between, operands: ["1", "2"]).isComplete)
        #expect(!FilterCondition(column: "a", op: .inList, operands: ["", ""]).isComplete)
        #expect(FilterCondition(column: "a", op: .inList, operands: ["", "x"]).isComplete)
        #expect(!FilterCondition(column: "a", op: .isNull, isEnabled: false).isComplete)
    }

    // MARK: - raw WHERE 高级模式

    @Test
    func rawWhereModePassesThroughWithoutParams() {
        let f = TableFilter(useRawWhere: true, rawWhere: "age > 18 AND name LIKE 'a%'")
        let result = f.buildWhere(dialect: .postgresql)
        #expect(result?.clause == "age > 18 AND name LIKE 'a%'")
        #expect(result?.params.isEmpty == true)
        #expect(f.isActive)
    }

    @Test
    func blankRawWhereIsInactive() {
        let f = TableFilter(useRawWhere: true, rawWhere: "   ")
        #expect(f.buildWhere(dialect: .sqlite) == nil)
        #expect(!f.isActive)
    }

    // MARK: - 预览

    @Test
    func previewInlinesLiterals() {
        let f = TableFilter(conditions: [
            FilterCondition(column: "age", op: .greaterThan, operands: ["18"]),
            FilterCondition(column: "name", op: .equals, operands: ["O'Brien"]),
        ])
        let preview = f.previewWhere(dialect: .sqlite, columns: [col("age", "integer"), col("name", "text")])
        #expect(preview == "WHERE \"age\" > 18 AND \"name\" = 'O''Brien'")
    }

    @Test
    func previewPostgresNumbered() {
        let preview = filter(.equals, ["ann"]).previewWhere(dialect: .postgresql)
        #expect(preview == "WHERE \"name\" = 'ann'")
    }

    @Test
    func previewNilWhenInactive() {
        #expect(TableFilter.empty.previewWhere(dialect: .sqlite) == nil)
    }

    // MARK: - 运算符可用性

    @Test
    func allOperatorsAvailableForSQLEngines() {
        for type in [DatabaseType.sqlite, .mysql, .postgresql] {
            for op in FilterOperator.allCases {
                #expect(op.isAvailable(for: type), "\(op) should be available for \(type)")
            }
        }
    }

    @Test
    func noOperatorsAvailableForRedis() {
        for op in FilterOperator.allCases {
            #expect(!op.isAvailable(for: .redis))
        }
    }
}