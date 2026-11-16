import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// 单元格编辑的数据完整性回归：
/// - BLOB 字面量曾一律生成 NULL（数据丢失）；
/// - 编辑文本曾不看列类型/原值类型，把文本列的 "123" 误转成整数。
@MainActor
struct TableChangeManagerTests {
    // MARK: - SQL 字面量

    @Test("BLOB 按方言生成十六进制字面量", arguments: [DatabaseType.sqlite, .mysql, .postgresql])
    func blobLiteralPerDialect(dialect: DatabaseType) {
        let value = DatabaseValue.data(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        let literal = sqlLiteral(for: value, dialect: dialect)
        switch dialect {
        case .sqlite, .mysql:
            #expect(literal == "X'deadbeef'")
        case .postgresql:
            #expect(literal == "'\\xdeadbeef'")
        case .redis:
            break
        }
        #expect(literal != "NULL")
    }

    @Test("空 BLOB 生成合法空字面量")
    func emptyBlobLiteral() {
        #expect(sqlLiteral(for: .data(Data()), dialect: .sqlite) == "X''")
        #expect(sqlLiteral(for: .data(Data()), dialect: .postgresql) == "'\\x'")
    }

    @Test("字符串字面量转义单引号")
    func stringEscaping() {
        #expect(sqlLiteral(for: .string("O'Brien"), dialect: .sqlite) == "'O''Brien'")
    }

    // MARK: - 类型感知解析

    @Test("整数列解析为 integer，文本列保持 string")
    func columnTypeAwareParsing() {
        #expect(parseEditedCellValue("42", columnType: "INTEGER") == .integer(42))
        #expect(parseEditedCellValue("42", columnType: "varchar(255)") == .string("42"))
        #expect(parseEditedCellValue("42", columnType: "TEXT") == .string("42"))
        #expect(parseEditedCellValue("3.14", columnType: "numeric(10,2)") == .double(3.14))
        #expect(parseEditedCellValue("true", columnType: "boolean") == .bool(true))
        // MySQL 用 tinyint(1) 表示 BOOLEAN：按布尔解析，true/false/1/0 都绑定为 1/0。
        #expect(parseEditedCellValue("1", columnType: "tinyint(1)") == .bool(true))
        #expect(parseEditedCellValue("false", columnType: "tinyint(1)") == .bool(false))
        #expect(parseEditedCellValue("1", columnType: "tinyint(4)") == .integer(1))
    }

    @Test("无列类型时沿用原值类型，文本不被误转数字")
    func originalTypePreserved() {
        #expect(parseEditedCellValue("123", original: .string("abc")) == .string("123"))
        #expect(parseEditedCellValue("456", original: .integer(1)) == .integer(456))
        #expect(parseEditedCellValue("2.5", original: .double(1.0)) == .double(2.5))
    }

    @Test("NULL 与空串语义区分")
    func nullVersusEmpty() {
        #expect(parseEditedCellValue("NULL") == .null)
        #expect(parseEditedCellValue(" null ") == .null)
        // 非 NULL 单元格清空 → 空字符串。
        #expect(parseEditedCellValue("", original: .string("x")) == .string(""))
        // NULL 单元格清空 → 保持 NULL（不意外写入空串）。
        #expect(parseEditedCellValue("", original: .null) == .null)
    }

    @Test("二进制列 hex 与 UTF-8 解析")
    func binaryParsing() {
        #expect(parseEditedCellValue("deadbeef", columnType: "BLOB") == .data(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(parseEditedCellValue("0xDEAD", columnType: "bytea") == .data(Data([0xDE, 0xAD])))
        #expect(parseEditedCellValue("hello", columnType: "BLOB") == .data(Data("hello".utf8)))
    }

    @Test("hex 编辑文本往返无损")
    func hexRoundTrip() {
        let data = Data([0x00, 0x01, 0xFE, 0xFF])
        let text = hexEditText(for: data)
        #expect(parseEditedCellValue(text, columnType: "BLOB") == .data(data))
    }

    // MARK: - 变更队列 SQL 生成

    private func makeManager() -> TableChangeManager {
        let table = DatabaseObject(kind: .table, name: "users")
        let schema = TableSchema(table: table, columns: [
            TableColumn(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true, defaultValue: nil, position: 0),
            TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1),
            TableColumn(name: "avatar", dataType: "BLOB", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 2),
        ])
        return TableChangeManager(table: table, schema: schema)
    }

    @Test("BLOB 单元格编辑生成的 UPDATE 不再写 NULL")
    func blobUpdateStatement() {
        let manager = makeManager()
        let row: [DatabaseValue] = [.integer(1), .string("ann"), .data(Data([0x01]))]
        let columns = ["id", "name", "avatar"]
        manager.stageCellUpdate(column: "avatar", newValue: .data(Data([0xAB, 0xCD])), rowValues: row, columns: columns)

        let statements = manager.generatedUpdateStatements(for: .sqlite)
        #expect(statements.count == 1)
        #expect(statements[0].contains("X'abcd'"))
        #expect(!statements[0].contains("NULL"))
    }

    @Test("DELETE→INSERT→UPDATE 顺序与主键定位")
    func statementOrderAndPK() {
        let manager = makeManager()
        let row: [DatabaseValue] = [.integer(7), .string("bob"), .null]
        let columns = ["id", "name", "avatar"]
        manager.stageCellUpdate(column: "name", newValue: .string("bobby"), rowValues: row, columns: columns)
        manager.toggleRowDeletion(rowValues: [.integer(9), .string("gone"), .null], columns: columns)
        let insertId = manager.addInsert()
        manager.setInsertColumn(insertId: insertId, column: "name", value: .string("new"))

        let all = manager.generatedAllStatements(for: .sqlite)
        #expect(all.count == 3)
        #expect(all[0].hasPrefix("DELETE"))
        #expect(all[1].hasPrefix("INSERT"))
        #expect(all[2].hasPrefix("UPDATE"))
        #expect(all[2].contains("WHERE \"id\" = 7"))
    }

    @Test("undo/redo 恢复变更队列")
    func undoRedo() {
        let manager = makeManager()
        let row: [DatabaseValue] = [.integer(1), .string("ann"), .null]
        let columns = ["id", "name", "avatar"]
        manager.stageCellUpdate(column: "name", newValue: .string("x"), rowValues: row, columns: columns)
        #expect(manager.changedCellCount == 1)
        manager.undo()
        #expect(manager.changedCellCount == 0)
        manager.redo()
        #expect(manager.changedCellCount == 1)
    }

    @Test("无主键表可编辑：全列 NULL-safe 匹配定位")
    func noPrimaryKeyFullRowMatch() {
        let table = DatabaseObject(kind: .table, name: "logs")
        let schema = TableSchema(table: table, columns: [
            TableColumn(name: "message", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 0),
            TableColumn(name: "level", dataType: "INTEGER", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1),
        ])
        let manager = TableChangeManager(table: table, schema: schema)
        #expect(manager.isEditable)
        let row: [DatabaseValue] = [.string("x"), .null]
        let columns = ["message", "level"]
        #expect(manager.rowKey(rowValues: row, columns: columns) != nil)
        manager.stageCellUpdate(column: "message", newValue: .string("y"), rowValues: row, columns: columns)
        let sql = manager.generatedUpdateStatements(for: .postgresql)[0]
        #expect(sql.contains("WHERE \"message\" = 'x' AND \"level\" IS NULL"))
    }

    @Test("列类型查询助手")
    func columnTypeLookup() {
        let manager = makeManager()
        #expect(manager.columnType(of: "avatar") == "BLOB")
        #expect(manager.columnType(of: "missing") == nil)
    }

    // MARK: - P2-2 置回默认值

    private func makeDefaultManager() -> TableChangeManager {
        let table = DatabaseObject(kind: .table, name: "items")
        let schema = TableSchema(table: table, columns: [
            TableColumn(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true, defaultValue: nil, position: 0),
            TableColumn(name: "status", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: "'new'", position: 1),
            TableColumn(name: "qty", dataType: "INTEGER", isNullable: true, isPrimaryKey: false, defaultValue: "0", position: 2),
        ])
        return TableChangeManager(table: table, schema: schema)
    }

    @Test("置回默认值生成 DEFAULT 关键字并计入变更")
    func stageDefaultEmitsKeyword() {
        let manager = makeDefaultManager()
        let row: [DatabaseValue] = [.integer(1), .string("done"), .integer(5)]
        let columns = ["id", "status", "qty"]
        manager.stageCellDefault(column: "status", rowValues: row, columns: columns)
        #expect(manager.changedCellCount == 1)
        #expect(manager.isCellChanged(column: "status", rowValues: row, columns: columns))
        #expect(manager.isCellDefault(column: "status", rowValues: row, columns: columns))
        #expect(!manager.isCellDefault(column: "qty", rowValues: row, columns: columns))
        let sql = manager.generatedUpdateStatements(for: .mysql)[0]
        #expect(sql.contains("`status` = DEFAULT"))
        #expect(sql.contains("WHERE `id` = 1"))
    }

    @Test("具体值与默认值互斥：后暂存的覆盖先暂存的")
    func concreteValueAndDefaultAreExclusive() {
        let manager = makeDefaultManager()
        let row: [DatabaseValue] = [.integer(1), .string("done"), .integer(5)]
        let columns = ["id", "status", "qty"]
        manager.stageCellDefault(column: "status", rowValues: row, columns: columns)
        manager.stageCellUpdate(column: "status", newValue: .string("x"), rowValues: row, columns: columns)
        #expect(!manager.isCellDefault(column: "status", rowValues: row, columns: columns))
        #expect(manager.changedCellCount == 1)
        var sql = manager.generatedUpdateStatements(for: .postgresql)[0]
        #expect(sql.contains("\"status\" = 'x'"))
        #expect(!sql.contains("DEFAULT"))

        manager.stageCellDefault(column: "status", rowValues: row, columns: columns)
        sql = manager.generatedUpdateStatements(for: .postgresql)[0]
        #expect(sql.contains("\"status\" = DEFAULT"))
        #expect(!sql.contains("'x'"))
        #expect(manager.changedCellCount == 1)
    }

    @Test("多列 SET 子句按列名排序（含 DEFAULT）")
    func multiColumnSetClauseSorted() {
        let manager = makeDefaultManager()
        let row: [DatabaseValue] = [.integer(1), .string("done"), .integer(5)]
        let columns = ["id", "status", "qty"]
        manager.stageCellUpdate(column: "qty", newValue: .integer(9), rowValues: row, columns: columns)
        manager.stageCellDefault(column: "status", rowValues: row, columns: columns)
        let sql = manager.generatedUpdateStatements(for: .mysql)[0]
        #expect(sql.contains("SET `qty` = 9, `status` = DEFAULT"))
        #expect(manager.changedCellCount == 2)
    }

    @Test("置回默认值可撤销/重做")
    func defaultUndoRedo() {
        let manager = makeDefaultManager()
        let row: [DatabaseValue] = [.integer(1), .string("done"), .integer(5)]
        let columns = ["id", "status", "qty"]
        manager.stageCellDefault(column: "status", rowValues: row, columns: columns)
        #expect(manager.hasChanges)
        manager.undo()
        #expect(!manager.hasChanges)
        manager.redo()
        #expect(manager.changedCellCount == 1)
    }

    @Test("恢复原值时同时清除该列的默认值暂存")
    func restoringOriginalClearsDefault() {
        let manager = makeDefaultManager()
        let row: [DatabaseValue] = [.integer(1), .string("done"), .integer(5)]
        let columns = ["id", "status", "qty"]
        manager.stageCellDefault(column: "status", rowValues: row, columns: columns)
        manager.stageCellUpdate(column: "status", newValue: .string("done"), rowValues: row, columns: columns)
        #expect(!manager.hasChanges)
    }

    @Test("新增行清除列值即恢复使用默认值")
    func insertClearColumnUsesDefault() {
        let manager = makeDefaultManager()
        let insertId = manager.addInsert()
        #expect(manager.insertUsesDefault(insertId: insertId, column: "status"))
        manager.setInsertColumn(insertId: insertId, column: "status", value: .string("x"))
        #expect(!manager.insertUsesDefault(insertId: insertId, column: "status"))
        manager.clearInsertColumn(insertId: insertId, column: "status")
        #expect(manager.insertUsesDefault(insertId: insertId, column: "status"))
        #expect(manager.insertDisplayValue(insertId: insertId, column: "status") == .null)
        // 未设值的列不出现在 INSERT 列清单里，由数据库填默认值。
        let sql = manager.generatedInsertStatements(for: .sqlite)[0]
        #expect(sql.contains("DEFAULT VALUES"))
    }
}