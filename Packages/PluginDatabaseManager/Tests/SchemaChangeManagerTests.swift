import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// DDL 暂存管理器（结构变更）：暂存校验、生效列视图、变更合并与各方言 SQL 生成。
/// 注意区别于 TableChangeManagerTests（单元格数据编辑）。
@MainActor
struct SchemaChangeManagerTests {
    private func makeManager(schema: String? = nil) -> SchemaChangeManager {
        let table = DatabaseObject(kind: .table, name: "users", schema: schema)
        return SchemaChangeManager(
            table: table,
            columns: [
                TableColumn(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true, defaultValue: nil, position: 0),
                TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1),
            ],
            indexes: [TableIndex(name: "idx_users_name", columns: ["name"], isUnique: false)]
        )
    }

    // MARK: - stageAdd

    @Test("新增列：修剪空白、空默认值归 nil、计入变更")
    func stageAddNormalizes() throws {
        let manager = makeManager()
        try manager.stageAdd(NewTableColumnDraft(name: "  age  ", dataType: " INTEGER ", defaultValue: "  "))
        #expect(manager.changes.count == 1)
        #expect(manager.hasChanges)
        #expect(!manager.hasDestructiveChanges)
        if case .addColumn(_, let column) = manager.changes[0] {
            #expect(column.name == "age")
            #expect(column.dataType == "INTEGER")
            #expect(column.defaultValue == nil)
        } else {
            Issue.record("expected addColumn")
        }
    }

    @Test("新增列：空名称与空类型被拒绝")
    func stageAddRejectsBlankFields() {
        let manager = makeManager()
        #expect(throws: SchemaChangeValidationError.blankName) {
            try manager.stageAdd(NewTableColumnDraft(name: "   ", dataType: "TEXT"))
        }
        #expect(throws: SchemaChangeValidationError.blankType) {
            try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "  "))
        }
        #expect(!manager.hasChanges)
    }

    @Test("新增列：类型与默认值携带危险 SQL 片段被拒绝")
    func stageAddRejectsUnsafeFragments() {
        let manager = makeManager()
        #expect(throws: SchemaChangeValidationError.unsafeSQLFragment) {
            try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "TEXT; DROP TABLE users"))
        }
        #expect(throws: SchemaChangeValidationError.unsafeSQLFragment) {
            try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "TEXT", defaultValue: "0 --x"))
        }
        #expect(throws: SchemaChangeValidationError.unsafeSQLFragment) {
            try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "TEXT /*c*/"))
        }
    }

    @Test("新增列：与原列或已暂存列重名（大小写不敏感）被拒绝")
    func stageAddRejectsDuplicates() throws {
        let manager = makeManager()
        #expect(throws: SchemaChangeValidationError.duplicateColumn("NAME")) {
            try manager.stageAdd(NewTableColumnDraft(name: "NAME", dataType: "TEXT"))
        }
        try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "INTEGER"))
        #expect(throws: SchemaChangeValidationError.duplicateColumn("Age")) {
            try manager.stageAdd(NewTableColumnDraft(name: "Age", dataType: "TEXT"))
        }
        #expect(manager.changes.count == 1)
    }

    @Test("新增列：NOT NULL 必须给默认值")
    func stageAddRequiresDefaultForNotNull() {
        let manager = makeManager()
        #expect(throws: SchemaChangeValidationError.requiredColumnNeedsDefault) {
            try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "INTEGER", isNullable: false))
        }
        #expect(throws: SchemaChangeValidationError.requiredColumnNeedsDefault) {
            try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "INTEGER", isNullable: false, defaultValue: "  "))
        }
        #expect(!manager.hasChanges)
    }

    // MARK: - stageRename

    @Test("重命名：拒绝空名、原名与撞名")
    func stageRenameValidation() throws {
        let manager = makeManager()
        #expect(throws: SchemaChangeValidationError.blankName) {
            try manager.stageRename(TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1), to: "  ")
        }
        let name = TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1)
        #expect(throws: SchemaChangeValidationError.unchangedName) {
            try manager.stageRename(name, to: "NAME")
        }
        #expect(throws: SchemaChangeValidationError.duplicateColumn("id")) {
            try manager.stageRename(name, to: "id")
        }
    }

    @Test("重命名：同一列的二次重命名替换旧暂存")
    func stageRenameReplacesPreviousEntry() throws {
        let manager = makeManager()
        let name = TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1)
        try manager.stageRename(name, to: "full_name")
        try manager.stageRename(name, to: "display_name")
        #expect(manager.changes.count == 1)
        if case .renameColumn(_, let oldName, let newName) = manager.changes[0] {
            #expect(oldName == "name")
            #expect(newName == "display_name")
        } else {
            Issue.record("expected renameColumn")
        }
        #expect(manager.changes[0].summary == "Rename ‘name’ to ‘display_name’")
    }

    // MARK: - stageDrop

    @Test("删除列：主键被拒绝，普通列标记破坏性")
    func stageDropValidation() throws {
        let manager = makeManager()
        let id = TableColumn(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true, defaultValue: nil, position: 0)
        #expect(throws: SchemaChangeValidationError.primaryKeyDrop("id")) {
            try manager.stageDrop(id)
        }
        let name = TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1)
        try manager.stageDrop(name)
        #expect(manager.hasDestructiveChanges)
        #expect(manager.changes[0].summary == "Drop column ‘name’")
        #expect(manager.changes[0].isDestructive)
    }

    @Test("删除列：撤掉同一列未生效的重命名暂存")
    func stageDropRemovesPendingRename() throws {
        let manager = makeManager()
        let name = TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1)
        try manager.stageRename(name, to: "full_name")
        try manager.stageDrop(name)
        #expect(manager.changes.count == 1)
        if case .dropColumn(_, let column) = manager.changes[0] {
            #expect(column.name == "name")
        } else {
            Issue.record("expected dropColumn")
        }
    }

    // MARK: - 索引

    @Test("新增索引：空名、空列、撞名、未知列被拒绝")
    func stageAddIndexValidation() throws {
        let manager = makeManager()
        #expect(throws: SchemaChangeValidationError.blankName) {
            try manager.stageAddIndex(NewTableIndexDraft(name: "  ", columns: ["name"]))
        }
        #expect(throws: SchemaChangeValidationError.missingIndexColumns) {
            try manager.stageAddIndex(NewTableIndexDraft(name: "idx_age", columns: []))
        }
        #expect(throws: SchemaChangeValidationError.duplicateIndex("IDX_USERS_NAME")) {
            try manager.stageAddIndex(NewTableIndexDraft(name: "IDX_USERS_NAME", columns: ["name"]))
        }
        #expect(throws: SchemaChangeValidationError.unknownIndexColumn("bogus")) {
            try manager.stageAddIndex(NewTableIndexDraft(name: "idx_bogus", columns: ["bogus"]))
        }
    }

    @Test("索引列基于生效列视图：重命名后可用新名，删除后的旧名不可用")
    func indexColumnsFollowEffectiveColumns() throws {
        let manager = makeManager()
        let name = TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1)
        try manager.stageRename(name, to: "full_name")
        try manager.stageAddIndex(NewTableIndexDraft(name: "idx_full", columns: ["full_name"]))
        #expect(manager.changes.count == 2)

        #expect(throws: SchemaChangeValidationError.unknownIndexColumn("name")) {
            try manager.stageAddIndex(NewTableIndexDraft(name: "idx_old", columns: ["name"]))
        }
    }

    @Test("新增索引：与已暂存索引撞名被拒绝")
    func stageAddIndexRejectsStagedDuplicate() throws {
        let manager = makeManager()
        try manager.stageAddIndex(NewTableIndexDraft(name: "idx_age", columns: ["id"]))
        #expect(throws: SchemaChangeValidationError.duplicateIndex("IDX_AGE")) {
            try manager.stageAddIndex(NewTableIndexDraft(name: "IDX_AGE", columns: ["id"]))
        }
    }

    @Test("删除索引：系统索引被保护，重复删除合并为一条")
    func stageDropIndex() throws {
        let manager = makeManager()
        #expect(throws: SchemaChangeValidationError.protectedIndex("primary")) {
            try manager.stageDropIndex(TableIndex(name: "primary", columns: ["id"], isUnique: true))
        }
        #expect(throws: SchemaChangeValidationError.protectedIndex("sqlite_autoindex_users_1")) {
            try manager.stageDropIndex(TableIndex(name: "sqlite_autoindex_users_1", columns: [], isUnique: true))
        }
        let index = TableIndex(name: "idx_users_name", columns: ["name"], isUnique: false)
        try manager.stageDropIndex(index)
        try manager.stageDropIndex(index)
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].summary == "Drop index ‘idx_users_name’")
    }

    // MARK: - 移除与清空

    @Test("remove 只删指定 id，discardAll 清空")
    func removeAndDiscard() throws {
        let manager = makeManager()
        try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "INTEGER"))
        try manager.stageAddIndex(NewTableIndexDraft(name: "idx_age", columns: ["age"]))
        #expect(manager.changes.count == 2)
        manager.remove(id: manager.changes[0].id)
        #expect(manager.changes.count == 1)
        manager.discardAll()
        #expect(manager.changes.isEmpty)
        #expect(!manager.hasChanges)
    }

    // MARK: - SQL 生成

    @Test("ADD COLUMN 按方言引用并携带 NOT NULL / DEFAULT")
    func addColumnStatements() throws {
        let manager = makeManager()
        try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "INTEGER", isNullable: false, defaultValue: "0"))

        #expect(manager.statements(for: .sqlite) == [
            "ALTER TABLE \"users\" ADD COLUMN \"age\" INTEGER NOT NULL DEFAULT 0;"
        ])
        #expect(manager.statements(for: .mysql) == [
            "ALTER TABLE `users` ADD COLUMN `age` INTEGER NOT NULL DEFAULT 0;"
        ])
        #expect(manager.statements(for: .postgresql) == [
            "ALTER TABLE \"users\" ADD COLUMN \"age\" INTEGER NOT NULL DEFAULT 0;"
        ])
    }

    @Test("DROP COLUMN 取代未生效的重命名暂存")
    func renameAndDropStatements() throws {
        let manager = makeManager()
        let name = TableColumn(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, position: 1)
        try manager.stageRename(name, to: "full_name")
        try manager.stageDrop(name)
        // 删除列已涵盖重命名意图，暂存只剩 DROP 一条。
        #expect(manager.statements(for: .sqlite) == ["ALTER TABLE \"users\" DROP COLUMN \"name\";"])
        #expect(manager.statements(for: .mysql) == ["ALTER TABLE `users` DROP COLUMN `name`;"])
    }

    @Test("ADD INDEX 按方言生成（MySQL 走 ALTER，SQLite/PG 走 CREATE）")
    func addIndexStatements() throws {
        let manager = makeManager()
        try manager.stageAddIndex(NewTableIndexDraft(name: "idx_multi", columns: ["id", "name"], isUnique: true))
        #expect(manager.statements(for: .sqlite) == [
            "CREATE UNIQUE INDEX \"idx_multi\" ON \"users\" (\"id\", \"name\");"
        ])
        #expect(manager.statements(for: .mysql) == [
            "ALTER TABLE `users` ADD UNIQUE INDEX `idx_multi` (`id`, `name`);"
        ])
        #expect(manager.statements(for: .postgresql) == [
            "CREATE UNIQUE INDEX \"idx_multi\" ON \"users\" (\"id\", \"name\");"
        ])
    }

    @Test("DROP INDEX：PostgreSQL 带 schema 时按 schema 限定")
    func dropIndexPostgresSchemaQualified() throws {
        let manager = makeManager(schema: "public")
        try manager.stageDropIndex(TableIndex(name: "idx_users_name", columns: ["name"], isUnique: false))
        #expect(manager.statements(for: .postgresql) == ["DROP INDEX \"public\".\"idx_users_name\";"])
        #expect(manager.statements(for: .sqlite) == ["DROP INDEX \"idx_users_name\";"])
        #expect(manager.statements(for: .mysql) == ["ALTER TABLE `users` DROP INDEX `idx_users_name`;"])
    }

    @Test("Redis 只保留列变更语句（不支持索引）")
    func redisIndexStatementsEmpty() throws {
        let manager = makeManager()
        try manager.stageAdd(NewTableColumnDraft(name: "age", dataType: "INTEGER"))
        try manager.stageAddIndex(NewTableIndexDraft(name: "idx_age", columns: ["age"]))
        try manager.stageDropIndex(TableIndex(name: "idx_users_name", columns: ["name"], isUnique: false))
        let statements = manager.statements(for: .redis)
        // 列变更仍会生成语句（标识符不加引号），索引语句被整体过滤。
        #expect(statements.count == 1)
        #expect(statements[0] == "ALTER TABLE users ADD COLUMN age INTEGER;")
    }
}
