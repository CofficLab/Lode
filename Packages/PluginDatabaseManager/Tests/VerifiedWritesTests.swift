import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// P1-6 写验证与冲突检测的单元测试：
/// - 行定位 WHERE 生成（主键 / 全列 NULL-safe / SQLite rowid）；
/// - affected rows 验证的跨引擎语义（MySQL UPDATE 允许 0，DELETE 恒要求 1，>1 一律中止）；
/// - 乐观锁冲突比对（changed / missing / ambiguous / 无冲突）；
/// - 变更队列的写计划顺序、原始快照捕获、rowid 定位、冲突行丢弃。
@MainActor
struct VerifiedWritesTests {
    // MARK: - WHERE 生成

    @Test("主键定位 WHERE（MySQL 反引号）")
    func primaryKeyWhere() {
        let locator = RowLocator.primaryKey([ColumnValue(column: "id", value: .integer(7))])
        #expect(whereClause(for: locator, dialect: .mysql) == "`id` = 7")
    }

    @Test("复合主键定位 WHERE 用 AND 连接")
    func compositePrimaryKeyWhere() {
        let locator = RowLocator.primaryKey([
            ColumnValue(column: "a", value: .integer(1)),
            ColumnValue(column: "b", value: .string("x")),
        ])
        #expect(whereClause(for: locator, dialect: .postgresql) == "\"a\" = 1 AND \"b\" = 'x'")
    }

    @Test("全列匹配 NULL-safe：NULL 列用 IS NULL")
    func fullRowNullSafeWhere() {
        let locator = RowLocator.fullRow([
            ColumnValue(column: "a", value: .string("x")),
            ColumnValue(column: "b", value: .null),
        ])
        #expect(whereClause(for: locator, dialect: .sqlite) == "\"a\" = 'x' AND \"b\" IS NULL")
    }

    @Test("SQLite rowid 定位 WHERE")
    func rowidWhere() {
        #expect(whereClause(for: .rowid(5), dialect: .sqlite) == "rowid = 5")
    }

    // MARK: - affected rows 验证

    @Test("MySQL UPDATE：0（匹配未改）与 1 均通过，2 中止")
    func mysqlUpdateAffected() {
        #expect(throws: Never.self) { try verifyAffectedRows(actual: 0, operation: .update, dialect: .mysql) }
        #expect(throws: Never.self) { try verifyAffectedRows(actual: 1, operation: .update, dialect: .mysql) }
        let err = #expect(throws: WriteVerificationError.self) { try verifyAffectedRows(actual: 2, operation: .update, dialect: .mysql) }
        #expect(err?.reason == .ambiguousRow)
    }

    @Test("PostgreSQL/SQLite UPDATE：0 中止，1 通过，2 中止", arguments: [DatabaseType.postgresql, .sqlite])
    func nonMySQLUpdateAffected(dialect: DatabaseType) {
        let zero = #expect(throws: WriteVerificationError.self) { try verifyAffectedRows(actual: 0, operation: .update, dialect: dialect) }
        #expect(zero?.reason == .affectedMismatch)
        #expect(throws: Never.self) { try verifyAffectedRows(actual: 1, operation: .update, dialect: dialect) }
        let two = #expect(throws: WriteVerificationError.self) { try verifyAffectedRows(actual: 2, operation: .update, dialect: dialect) }
        #expect(two?.reason == .ambiguousRow)
    }

    @Test("DELETE：所有引擎 0 中止、1 通过、2 中止", arguments: [DatabaseType.mysql, .postgresql, .sqlite])
    func deleteAffected(dialect: DatabaseType) {
        let zero = #expect(throws: WriteVerificationError.self) { try verifyAffectedRows(actual: 0, operation: .delete, dialect: dialect) }
        #expect(zero?.reason == .affectedMismatch)
        #expect(throws: Never.self) { try verifyAffectedRows(actual: 1, operation: .delete, dialect: dialect) }
        let two = #expect(throws: WriteVerificationError.self) { try verifyAffectedRows(actual: 2, operation: .delete, dialect: dialect) }
        #expect(two?.reason == .ambiguousRow)
    }

    // MARK: - 冲突比对

    private func makeTarget() -> RowTarget {
        RowTarget(
            key: "id=1",
            locator: .primaryKey([ColumnValue(column: "id", value: .integer(1))]),
            originalRow: ["id": .integer(1), "name": .string("ann")],
            columnUpdates: ["name": .string("anne")],
            isDelete: false
        )
    }

    @Test("当前行与原始快照一致 → 无冲突")
    func noConflict() {
        let result = QueryResult(columns: ["id", "name"], rows: [[.integer(1), .string("ann")]], rowsAffected: 0)
        #expect(detectRowConflict(target: makeTarget(), result: result) == nil)
    }

    @Test("他人改动内容 → changed 并列出差异列")
    func changedConflict() {
        let result = QueryResult(columns: ["id", "name"], rows: [[.integer(1), .string("bob")]], rowsAffected: 0)
        let conflict = detectRowConflict(target: makeTarget(), result: result)
        #expect(conflict?.kind == .changed)
        #expect(conflict?.changedColumns == ["name"])
        #expect(conflict?.currentRow?["name"] == .string("bob"))
    }

    @Test("重读为空 → missing")
    func missingConflict() {
        let result = QueryResult(columns: ["id", "name"], rows: [], rowsAffected: 0)
        let conflict = detectRowConflict(target: makeTarget(), result: result)
        #expect(conflict?.kind == .missing)
        #expect(conflict?.currentRow == nil)
    }

    @Test("重读命中多行 → ambiguous")
    func ambiguousConflict() {
        let result = QueryResult(columns: ["id", "name"], rows: [[.integer(1), .string("ann")], [.integer(1), .string("ann")]], rowsAffected: 0)
        #expect(detectRowConflict(target: makeTarget(), result: result)?.kind == .ambiguous)
    }

    // MARK: - 变更队列写计划

    private func makePKManager() -> TableChangeManager {
        let table = DatabaseObject(kind: .table, name: "users")
        let schema = TableSchema(table: table, columns: [
            TableColumn(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true, defaultValue: nil, position: 0),
            TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1),
        ])
        return TableChangeManager(table: table, schema: schema)
    }

    @Test("写计划顺序 DELETE→INSERT→UPDATE，目标一一对应")
    func writePlanOrderAndTargets() {
        let manager = makePKManager()
        let columns = ["id", "name"]
        manager.toggleRowDeletion(rowValues: [.integer(9), .string("gone")], columns: columns)
        let insertId = manager.addInsert()
        manager.setInsertColumn(insertId: insertId, column: "name", value: .string("new"))
        manager.stageCellUpdate(column: "name", newValue: .string("bobby"), rowValues: [.integer(7), .string("bob")], columns: columns)

        let plan = manager.writePlan(for: .sqlite)
        #expect(plan.map(\.kind) == [.delete, .insert, .update])
        #expect(plan[0].target?.isDelete == true)
        #expect(plan[0].target?.locator == .primaryKey([ColumnValue(column: "id", value: .integer(9))]))
        #expect(plan[1].target == nil)
        #expect(plan[2].target?.isDelete == false)
        #expect(plan[2].target?.originalRow == ["id": .integer(7), "name": .string("bob")])
        #expect(plan[2].target?.columnUpdates == ["name": .string("bobby")])
    }

    @Test("原始快照在首次暂存时捕获，后续编辑不改原始值")
    func originalSnapshotStable() {
        let manager = makePKManager()
        let columns = ["id", "name"]
        let row: [DatabaseValue] = [.integer(7), .string("bob")]
        manager.stageCellUpdate(column: "name", newValue: .string("bobby"), rowValues: row, columns: columns)
        manager.stageCellUpdate(column: "name", newValue: .string("bobbier"), rowValues: row, columns: columns)
        #expect(manager.rowTargets[0].originalRow["name"] == .string("bob"))
        #expect(manager.rowTargets[0].columnUpdates["name"] == .string("bobbier"))
    }

    @Test("SQLite 无主键表用 rowid 定位，快照不含 rowid 别名")
    func sqliteRowidLocator() {
        let table = DatabaseObject(kind: .table, name: "t")
        let schema = TableSchema(table: table, columns: [
            TableColumn(name: "val", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 0),
        ])
        let manager = TableChangeManager(table: table, schema: schema)
        let row: [DatabaseValue] = [.integer(3), .string("a")]
        let columns = ["rowid", "val"]
        #expect(manager.rowKey(rowValues: row, columns: columns) == "rowid=3")
        manager.stageCellUpdate(column: "val", newValue: .string("b"), rowValues: row, columns: columns)
        let target = manager.rowTargets[0]
        #expect(target.locator == .rowid(3))
        #expect(target.originalRow == ["val": .string("a")])
        #expect(manager.reReadStatement(for: target, dialect: .sqlite) == "SELECT * FROM \"t\" WHERE rowid = 3;")
        #expect(manager.generatedUpdateStatements(for: .sqlite)[0].contains("WHERE rowid = 3"))
    }

    @Test("无主键表（无 rowid）用全列定位")
    func noPKFullRowLocator() {
        let table = DatabaseObject(kind: .table, name: "logs")
        let schema = TableSchema(table: table, columns: [
            TableColumn(name: "msg", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 0),
        ])
        let manager = TableChangeManager(table: table, schema: schema)
        manager.stageCellUpdate(column: "msg", newValue: .string("y"), rowValues: [.string("x")], columns: ["msg"])
        #expect(manager.rowTargets[0].locator == .fullRow([ColumnValue(column: "msg", value: .string("x"))]))
    }

    @Test("removeRowChanges 丢弃指定行的更新与删除")
    func removeRowChanges() {
        let manager = makePKManager()
        let columns = ["id", "name"]
        manager.stageCellUpdate(column: "name", newValue: .string("x"), rowValues: [.integer(1), .string("a")], columns: columns)
        manager.toggleRowDeletion(rowValues: [.integer(2), .string("b")], columns: columns)
        #expect(manager.rowTargets.count == 2)
        let key = manager.rowKey(rowValues: [.integer(1), .string("a")], columns: columns)!
        manager.removeRowChanges(forKey: key)
        #expect(manager.rowTargets.count == 1)
        #expect(manager.rowTargets[0].isDelete)
        #expect(manager.changedCellCount == 0)
        #expect(manager.pendingDeleteCount == 1)
    }
}