import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-3a 建表 DDL 生成离线单测：跨引擎列定义/NOT NULL/DEFAULT/复合主键/唯一与非唯一索引/
// 外键 ON DELETE/UPDATE/标识符引用/MySQL ENGINE=InnoDB/库 schema 限定，以及校验拒绝路径。
// 真实引擎端到端建表见 CreateTableIntegrationTests。

private func col(_ name: String, _ type: String, nullable: Bool = true, default defaultValue: String? = nil) -> NewTableColumnDraft {
    NewTableColumnDraft(name: name, dataType: type, isNullable: nullable, defaultValue: defaultValue)
}

private func sampleDraft() -> NewTableDraft {
    NewTableDraft(
        name: "orders",
        columns: [
            col("id", "INTEGER", nullable: false),
            col("customer_id", "INTEGER"),
            col("label", "TEXT", nullable: false, default: "'unknown'"),
            col("amount", "REAL"),
        ],
        primaryKey: ["id"],
        indexes: [
            NewTableIndexDraft(name: "idx_orders_customer", columns: ["customer_id"], isUnique: false),
            NewTableIndexDraft(name: "uq_orders_label", columns: ["label"], isUnique: true),
        ],
        foreignKeys: [
            NewTableForeignKeyDraft(columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"], onDelete: "CASCADE", onUpdate: "SET NULL"),
        ]
    )
}

@Suite(.serialized)
struct CreateTableValidationTests {
    @Test func acceptsWellFormedDraft() throws {
        try CreateTableDDLGenerator.validate(sampleDraft())
    }

    @Test func rejectsBlankTableName() {
        var draft = sampleDraft()
        draft.name = "   "
        #expect(throws: CreateTableValidationError.blankTableName) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsNoColumns() {
        let draft = NewTableDraft(name: "t", columns: [])
        #expect(throws: CreateTableValidationError.noColumns) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsBlankColumnName() {
        let draft = NewTableDraft(name: "t", columns: [col("  ", "TEXT")])
        #expect(throws: CreateTableValidationError.blankColumnName) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsBlankColumnType() {
        let draft = NewTableDraft(name: "t", columns: [col("a", " ")])
        #expect(throws: CreateTableValidationError.blankColumnType) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsDuplicateColumnCaseInsensitive() {
        let draft = NewTableDraft(name: "t", columns: [col("Id", "INTEGER"), col("id", "TEXT")])
        #expect(throws: CreateTableValidationError.duplicateColumn("id")) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsUnsafeTypeFragment() {
        let draft = NewTableDraft(name: "t", columns: [col("a", "INTEGER; DROP TABLE x")])
        #expect(throws: CreateTableValidationError.unsafeSQLFragment) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsUnsafeDefaultFragment() {
        let draft = NewTableDraft(name: "t", columns: [col("a", "TEXT", default: "x -- comment")])
        #expect(throws: CreateTableValidationError.unsafeSQLFragment) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func notNullColumnNeedsNoDefaultOnCreate() throws {
        // 建表与改表不同：NOT NULL 列无需默认值。
        let draft = NewTableDraft(name: "t", columns: [col("a", "INTEGER", nullable: false)])
        try CreateTableDDLGenerator.validate(draft)
    }

    @Test func rejectsUnknownPrimaryKeyColumn() {
        var draft = sampleDraft()
        draft.primaryKey = ["missing"]
        #expect(throws: CreateTableValidationError.unknownColumn("missing")) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsIndexBlankName() {
        var draft = sampleDraft()
        draft.indexes = [NewTableIndexDraft(name: " ", columns: ["id"])]
        #expect(throws: CreateTableValidationError.indexBlankName) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsIndexNoColumns() {
        var draft = sampleDraft()
        draft.indexes = [NewTableIndexDraft(name: "idx", columns: [])]
        #expect(throws: CreateTableValidationError.indexNoColumns) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsUnknownIndexColumn() {
        var draft = sampleDraft()
        draft.indexes = [NewTableIndexDraft(name: "idx", columns: ["ghost"])]
        #expect(throws: CreateTableValidationError.unknownColumn("ghost")) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsDuplicateIndexName() {
        var draft = sampleDraft()
        draft.indexes = [
            NewTableIndexDraft(name: "idx", columns: ["id"]),
            NewTableIndexDraft(name: "IDX", columns: ["amount"]),
        ]
        #expect(throws: CreateTableValidationError.duplicateIndexName("IDX")) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsForeignKeyBlankTable() {
        var draft = sampleDraft()
        draft.foreignKeys = [NewTableForeignKeyDraft(columns: ["customer_id"], referencedTable: " ", referencedColumns: ["id"])]
        #expect(throws: CreateTableValidationError.foreignKeyBlankTable) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsForeignKeyColumnCountMismatch() {
        var draft = sampleDraft()
        draft.foreignKeys = [NewTableForeignKeyDraft(columns: ["customer_id", "amount"], referencedTable: "customers", referencedColumns: ["id"])]
        #expect(throws: CreateTableValidationError.foreignKeyColumnMismatch) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsForeignKeyEmptyColumns() {
        var draft = sampleDraft()
        draft.foreignKeys = [NewTableForeignKeyDraft(columns: [], referencedTable: "customers", referencedColumns: [])]
        #expect(throws: CreateTableValidationError.foreignKeyColumnMismatch) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsUnknownForeignKeyColumn() {
        var draft = sampleDraft()
        draft.foreignKeys = [NewTableForeignKeyDraft(columns: ["ghost"], referencedTable: "customers", referencedColumns: ["id"])]
        #expect(throws: CreateTableValidationError.unknownColumn("ghost")) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func rejectsInvalidReferentialAction() {
        var draft = sampleDraft()
        draft.foreignKeys = [NewTableForeignKeyDraft(columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"], onDelete: "DROP")]
        #expect(throws: CreateTableValidationError.invalidReferentialAction("DROP")) { try CreateTableDDLGenerator.validate(draft) }
    }

    @Test func acceptsAllReferentialActions() throws {
        for action in ["CASCADE", "SET NULL", "SET DEFAULT", "RESTRICT", "NO ACTION"] {
            var draft = sampleDraft()
            draft.foreignKeys = [NewTableForeignKeyDraft(columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"], onDelete: action, onUpdate: action)]
            try CreateTableDDLGenerator.validate(draft)
        }
    }
}

@Suite(.serialized)
struct CreateTableDDLStatementTests {
    @Test func sqliteQuotesWithDoubleQuotesAndNoEngine() {
        let sql = CreateTableDDLGenerator.statements(sampleDraft(), type: .sqlite)
        let create = sql[0]
        #expect(create.contains("CREATE TABLE \"orders\" ("))
        #expect(create.contains("\"id\" INTEGER NOT NULL"))
        #expect(create.contains("\"label\" TEXT NOT NULL DEFAULT 'unknown'"))
        #expect(create.contains("\"amount\" REAL"))
        #expect(create.contains("PRIMARY KEY (\"id\")"))
        #expect(create.contains("FOREIGN KEY (\"customer_id\") REFERENCES \"customers\" (\"id\") ON DELETE CASCADE ON UPDATE SET NULL"))
        #expect(!create.contains("ENGINE"))
        #expect(sql.contains("CREATE INDEX \"idx_orders_customer\" ON \"orders\" (\"customer_id\");"))
        #expect(sql.contains("CREATE UNIQUE INDEX \"uq_orders_label\" ON \"orders\" (\"label\");"))
        #expect(sql.count == 3)
    }

    @Test func mysqlUsesBackticksEngineInnoDBAndAlterIndex() {
        let sql = CreateTableDDLGenerator.statements(sampleDraft(), type: .mysql, database: "shop")
        let create = sql[0]
        #expect(create.contains("CREATE TABLE `shop`.`orders` ("))
        #expect(create.contains("`id` INTEGER NOT NULL"))
        #expect(create.contains("PRIMARY KEY (`id`)"))
        #expect(create.contains("REFERENCES `shop`.`customers` (`id`)"))
        #expect(create.hasSuffix(") ENGINE=InnoDB;"))
        #expect(sql.contains("ALTER TABLE `shop`.`orders` ADD INDEX `idx_orders_customer` (`customer_id`);"))
        #expect(sql.contains("ALTER TABLE `shop`.`orders` ADD UNIQUE INDEX `uq_orders_label` (`label`);"))
    }

    @Test func postgresUsesSchemaQualificationAndCreateIndex() {
        let sql = CreateTableDDLGenerator.statements(sampleDraft(), type: .postgresql, schema: "sales")
        let create = sql[0]
        #expect(create.contains("CREATE TABLE \"sales\".\"orders\" ("))
        #expect(create.contains("REFERENCES \"sales\".\"customers\" (\"id\")"))
        #expect(!create.contains("ENGINE"))
        #expect(sql.contains("CREATE INDEX \"idx_orders_customer\" ON \"sales\".\"orders\" (\"customer_id\");"))
        #expect(sql.contains("CREATE UNIQUE INDEX \"uq_orders_label\" ON \"sales\".\"orders\" (\"label\");"))
    }

    @Test func compositePrimaryKeyPreservesOrder() {
        let draft = NewTableDraft(
            name: "memberships",
            columns: [col("user_id", "INTEGER", nullable: false), col("group_id", "INTEGER", nullable: false), col("role", "TEXT")],
            primaryKey: ["group_id", "user_id"]
        )
        let create = CreateTableDDLGenerator.statements(draft, type: .sqlite)[0]
        #expect(create.contains("PRIMARY KEY (\"group_id\", \"user_id\")"))
    }

    @Test func noPrimaryKeyOmitsClause() {
        let draft = NewTableDraft(name: "t", columns: [col("a", "TEXT")])
        let create = CreateTableDDLGenerator.statements(draft, type: .sqlite)[0]
        #expect(!create.contains("PRIMARY KEY"))
        #expect(create.contains("\"a\" TEXT"))
    }

    @Test func nullableColumnOmitsNotNull() {
        let draft = NewTableDraft(name: "t", columns: [col("a", "TEXT", nullable: true)])
        let create = CreateTableDDLGenerator.statements(draft, type: .postgresql)[0]
        #expect(!create.contains("NOT NULL"))
    }

    @Test func foreignKeyWithoutActionsOmitsClauses() {
        let draft = NewTableDraft(
            name: "child",
            columns: [col("pid", "INTEGER")],
            foreignKeys: [NewTableForeignKeyDraft(columns: ["pid"], referencedTable: "parent", referencedColumns: ["id"])]
        )
        let create = CreateTableDDLGenerator.statements(draft, type: .sqlite)[0]
        #expect(create.contains("FOREIGN KEY (\"pid\") REFERENCES \"parent\" (\"id\")"))
        #expect(!create.contains("ON DELETE"))
        #expect(!create.contains("ON UPDATE"))
    }

    @Test func identifierWithQuoteIsEscaped() {
        let draft = NewTableDraft(name: "we\"ird", columns: [col("a\"b", "TEXT")])
        let create = CreateTableDDLGenerator.statements(draft, type: .sqlite)[0]
        #expect(create.contains("CREATE TABLE \"we\"\"ird\""))
        #expect(create.contains("\"a\"\"b\" TEXT"))
    }

    @Test func previewJoinsStatementsWithBlankLine() {
        let preview = CreateTableDDLGenerator.preview(sampleDraft(), type: .sqlite)
        #expect(preview.contains("CREATE TABLE"))
        #expect(preview.contains("\n\nCREATE INDEX"))
        #expect(preview.contains("\n\nCREATE UNIQUE INDEX"))
    }

    @Test func noIndexesProducesSingleStatement() {
        let draft = NewTableDraft(name: "t", columns: [col("a", "TEXT")])
        #expect(CreateTableDDLGenerator.statements(draft, type: .mysql).count == 1)
    }
}