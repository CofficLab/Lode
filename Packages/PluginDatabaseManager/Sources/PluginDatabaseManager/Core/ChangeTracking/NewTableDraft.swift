import Foundation

/// 新建表草稿：列（复用 ``NewTableColumnDraft``）、主键（可复合）、索引（含唯一）、外键。
/// 与改表草稿分离——建表时 NOT NULL 列无需默认值，约束以表级子句表达。
public struct NewTableDraft: Equatable, Sendable {
    public var name: String
    public var columns: [NewTableColumnDraft]
    /// 主键列名（按序）；空表示无主键。
    public var primaryKey: [String]
    public var indexes: [NewTableIndexDraft]
    public var foreignKeys: [NewTableForeignKeyDraft]

    public init(
        name: String = "",
        columns: [NewTableColumnDraft] = [],
        primaryKey: [String] = [],
        indexes: [NewTableIndexDraft] = [],
        foreignKeys: [NewTableForeignKeyDraft] = []
    ) {
        self.name = name
        self.columns = columns
        self.primaryKey = primaryKey
        self.indexes = indexes
        self.foreignKeys = foreignKeys
    }
}

/// 新建表的外键草稿。引用表默认与新表同库/schema。
public struct NewTableForeignKeyDraft: Equatable, Sendable {
    public var columns: [String]
    public var referencedTable: String
    public var referencedColumns: [String]
    /// CASCADE / SET NULL / SET DEFAULT / RESTRICT / NO ACTION；nil 表示省略。
    public var onDelete: String?
    public var onUpdate: String?

    public init(
        columns: [String] = [],
        referencedTable: String = "",
        referencedColumns: [String] = [],
        onDelete: String? = nil,
        onUpdate: String? = nil
    ) {
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}

/// 建表草稿校验错误（独立于改表错误，文案自洽）。
public enum CreateTableValidationError: LocalizedError, Equatable {
    case blankTableName
    case noColumns
    case blankColumnName
    case blankColumnType
    case unsafeSQLFragment
    case duplicateColumn(String)
    case unknownColumn(String)
    case indexBlankName
    case indexNoColumns
    case duplicateIndexName(String)
    case foreignKeyBlankTable
    case foreignKeyColumnMismatch
    case invalidReferentialAction(String)

    public var errorDescription: String? {
        switch self {
        case .blankTableName: "Table name cannot be empty."
        case .noColumns: "Add at least one column."
        case .blankColumnName: "Column name cannot be empty."
        case .blankColumnType: "Column type cannot be empty."
        case .unsafeSQLFragment: "Column type or default contains an unsafe SQL fragment."
        case .duplicateColumn(let name): "A column named ‘\(name)’ appears more than once."
        case .unknownColumn(let name): "Column ‘\(name)’ does not exist in this table."
        case .indexBlankName: "Index name cannot be empty."
        case .indexNoColumns: "Select at least one column for the index."
        case .duplicateIndexName(let name): "An index named ‘\(name)’ appears more than once."
        case .foreignKeyBlankTable: "Foreign key must reference a table."
        case .foreignKeyColumnMismatch: "Foreign key columns and referenced columns must match in number."
        case .invalidReferentialAction(let action): "‘\(action)’ is not a valid referential action."
        }
    }
}

/// 跨引擎 CREATE TABLE DDL 纯函数生成器。标识符按方言引用，约束以表级子句表达，
/// 索引另起语句（MySQL 用 ALTER TABLE ADD INDEX，SQLite/PG 用 CREATE INDEX）。
/// 类型/默认值原样输出但经 ``isSafeSQLFragment`` 防注入；标识符经引用转义。
public enum CreateTableDDLGenerator {
    /// 校验草稿；通过后方可生成 DDL。
    public static func validate(_ draft: NewTableDraft) throws {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CreateTableValidationError.blankTableName
        }
        guard !draft.columns.isEmpty else { throw CreateTableValidationError.noColumns }

        var columnNames = Set<String>()
        for column in draft.columns {
            let name = column.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = column.dataType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw CreateTableValidationError.blankColumnName }
            guard !type.isEmpty else { throw CreateTableValidationError.blankColumnType }
            guard isSafeSQLFragment(type), column.defaultValue.map(isSafeSQLFragment) ?? true else {
                throw CreateTableValidationError.unsafeSQLFragment
            }
            let key = name.lowercased()
            guard !columnNames.contains(key) else { throw CreateTableValidationError.duplicateColumn(name) }
            columnNames.insert(key)
        }

        func requireColumns(_ names: [String]) throws {
            for name in names where !columnNames.contains(name.lowercased()) {
                throw CreateTableValidationError.unknownColumn(name)
            }
        }

        try requireColumns(draft.primaryKey)

        var indexNames = Set<String>()
        for index in draft.indexes {
            let name = index.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw CreateTableValidationError.indexBlankName }
            guard !index.columns.isEmpty else { throw CreateTableValidationError.indexNoColumns }
            try requireColumns(index.columns)
            let key = name.lowercased()
            guard !indexNames.contains(key) else { throw CreateTableValidationError.duplicateIndexName(name) }
            indexNames.insert(key)
        }

        for foreignKey in draft.foreignKeys {
            guard !foreignKey.referencedTable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CreateTableValidationError.foreignKeyBlankTable
            }
            guard !foreignKey.columns.isEmpty,
                  foreignKey.columns.count == foreignKey.referencedColumns.count else {
                throw CreateTableValidationError.foreignKeyColumnMismatch
            }
            try requireColumns(foreignKey.columns)
            for action in [foreignKey.onDelete, foreignKey.onUpdate].compactMap({ $0 }) {
                guard referentialActions.contains(action.uppercased()) else {
                    throw CreateTableValidationError.invalidReferentialAction(action)
                }
            }
        }
    }

    /// 生成建表 + 索引语句（假定草稿已校验）。database/schema 用于限定表名与引用表名。
    public static func statements(
        _ draft: NewTableDraft,
        type: DatabaseType,
        database: String? = nil,
        schema: String? = nil
    ) -> [String] {
        let tableObject = DatabaseObject(kind: .table, name: draft.name, database: database, schema: schema)
        let tableName = DatabaseViewModel.qualifiedName(for: tableObject, type: type)

        var lines = draft.columns.map { columnDefinition($0, type: type) }
        if !draft.primaryKey.isEmpty {
            let columns = draft.primaryKey.map { DatabaseViewModel.quoteIdentifier($0, for: type) }.joined(separator: ", ")
            lines.append("PRIMARY KEY (\(columns))")
        }
        for foreignKey in draft.foreignKeys {
            let refObject = DatabaseObject(kind: .table, name: foreignKey.referencedTable, database: database, schema: schema)
            let refName = DatabaseViewModel.qualifiedName(for: refObject, type: type)
            let columns = foreignKey.columns.map { DatabaseViewModel.quoteIdentifier($0, for: type) }.joined(separator: ", ")
            let refColumns = foreignKey.referencedColumns.map { DatabaseViewModel.quoteIdentifier($0, for: type) }.joined(separator: ", ")
            var clause = "FOREIGN KEY (\(columns)) REFERENCES \(refName) (\(refColumns))"
            if let onDelete = foreignKey.onDelete { clause += " ON DELETE \(onDelete.uppercased())" }
            if let onUpdate = foreignKey.onUpdate { clause += " ON UPDATE \(onUpdate.uppercased())" }
            lines.append(clause)
        }

        let body = lines.map { "  \($0)" }.joined(separator: ",\n")
        let engineSuffix = type == .mysql ? " ENGINE=InnoDB" : ""
        var result = ["CREATE TABLE \(tableName) (\n\(body)\n)\(engineSuffix);"]

        for index in draft.indexes {
            let name = DatabaseViewModel.quoteIdentifier(index.name, for: type)
            let columns = index.columns.map { DatabaseViewModel.quoteIdentifier($0, for: type) }.joined(separator: ", ")
            let unique = index.isUnique ? "UNIQUE " : ""
            switch type {
            case .mysql:
                result.append("ALTER TABLE \(tableName) ADD \(unique)INDEX \(name) (\(columns));")
            case .sqlite, .postgresql:
                result.append("CREATE \(unique)INDEX \(name) ON \(tableName) (\(columns));")
            case .redis:
                break
            }
        }
        return result
    }

    /// 预览文本：语句以空行分隔。
    public static func preview(_ draft: NewTableDraft, type: DatabaseType, database: String? = nil, schema: String? = nil) -> String {
        statements(draft, type: type, database: database, schema: schema).joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private static let referentialActions: Set<String> = ["CASCADE", "SET NULL", "SET DEFAULT", "RESTRICT", "NO ACTION"]

    private static func columnDefinition(_ column: NewTableColumnDraft, type: DatabaseType) -> String {
        var parts = [DatabaseViewModel.quoteIdentifier(column.name, for: type), column.dataType]
        if !column.isNullable { parts.append("NOT NULL") }
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty { parts.append("DEFAULT \(defaultValue)") }
        return parts.joined(separator: " ")
    }

    /// 类型/默认值原样拼入 DDL，故拒绝语句分隔与注释注入片段。
    static func isSafeSQLFragment(_ value: String) -> Bool {
        !value.contains(";") && !value.contains("--") && !value.contains("/*") && !value.contains("*/")
    }
}