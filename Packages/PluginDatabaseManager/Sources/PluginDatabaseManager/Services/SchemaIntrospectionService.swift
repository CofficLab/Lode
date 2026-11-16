import Foundation

/// 数据库结构自省服务：把各引擎的 catalog 查询统一成 ``DatabaseObject`` / ``TableSchema``。
///
/// UI（侧边栏树、结构 Tab）只依赖此协议，不感知具体 SQL 方言。
/// Redis 没有关系型结构，不实现此协议——其键浏览走专门的 SCAN 路径。
public protocol DatabaseIntrospector: Sendable {
    func loadDatabases(in connection: any DatabaseConnection) async throws -> [String]
    func loadSchemas(in connection: any DatabaseConnection, database: String?) async throws -> [String]
    func loadObjects(
        of kind: DatabaseObjectKind,
        in connection: any DatabaseConnection,
        database: String?,
        schema: String?
    ) async throws -> [DatabaseObject]
    func describeTable(
        _ object: DatabaseObject,
        in connection: any DatabaseConnection
    ) async throws -> TableSchema
    func loadDDL(
        for object: DatabaseObject,
        in connection: any DatabaseConnection
    ) async throws -> String?
}

// MARK: - DatabaseType routing

public extension DatabaseType {
    var introspector: any DatabaseIntrospector {
        switch self {
        case .sqlite: return SQLiteIntrospector()
        case .mysql: return MySQLIntrospector()
        case .postgresql: return PostgreSQLIntrospector()
        case .redis: return EmptyIntrospector()
        }
    }
}

/// Redis 占位实现：Redis 没有关系型结构，所有调用返回空。
public struct EmptyIntrospector: DatabaseIntrospector {
    public init() {}
    public func loadDatabases(in connection: any DatabaseConnection) async throws -> [String] { [] }
    public func loadSchemas(in connection: any DatabaseConnection, database: String?) async throws -> [String] { [] }
    public func loadObjects(of kind: DatabaseObjectKind, in connection: any DatabaseConnection, database: String?, schema: String?) async throws -> [DatabaseObject] { [] }
    public func describeTable(_ object: DatabaseObject, in connection: any DatabaseConnection) async throws -> TableSchema {
        TableSchema(table: object, columns: [])
    }
    public func loadDDL(for object: DatabaseObject, in connection: any DatabaseConnection) async throws -> String? { nil }
}

// MARK: - QueryResult row decoding helpers

enum SchemaRowDecoder {
    static func string(_ row: [DatabaseValue], at index: Int) -> String? {
        guard index < row.count else { return nil }
        switch row[index] {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        // MySQL 8 的 information_schema 文本列按 blob 线上类型返回 .data；元数据恒为文本，按 UTF-8 还原。
        case .data(let d): return String(data: d, encoding: .utf8)
        case .null: return nil
        }
    }

    static func int(_ row: [DatabaseValue], at index: Int) -> Int? {
        guard index < row.count else { return nil }
        switch row[index] {
        case .integer(let i): return i
        case .string(let s): return Int(s)
        case .double(let d): return Int(d)
        case .bool(let b): return b ? 1 : 0
        case .data, .null: return nil
        }
    }
}

// MARK: - SQLite

/// SQLite 自省：基于 `sqlite_master` 与 `PRAGMA`。
public struct SQLiteIntrospector: DatabaseIntrospector {
    public init() {}

    public func loadDatabases(in connection: any DatabaseConnection) async throws -> [String] {
        []  // SQLite 是单文件库；ATTACH 的库暂不支持在树中切换
    }

    public func loadSchemas(in connection: any DatabaseConnection, database: String?) async throws -> [String] {
        []
    }

    public func loadObjects(
        of kind: DatabaseObjectKind,
        in connection: any DatabaseConnection,
        database: String?,
        schema: String?
    ) async throws -> [DatabaseObject] {
        let typeLiteral: String
        switch kind {
        case .table: typeLiteral = "table"
        case .view: typeLiteral = "view"
        case .index: typeLiteral = "index"
        case .trigger: typeLiteral = "trigger"
        case .materializedView, .procedure, .function:
            return []  // SQLite 不支持
        }
        let sql = """
        SELECT name, sql FROM sqlite_master
        WHERE type = '\(typeLiteral)' AND name NOT LIKE 'sqlite_%'
        ORDER BY name;
        """
        let result = try await connection.query(sql, params: nil)
        return result.rows.compactMap { row -> DatabaseObject? in
            guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
            return DatabaseObject(kind: kind, name: name)
        }
    }

    public func describeTable(_ object: DatabaseObject, in connection: any DatabaseConnection) async throws -> TableSchema {
        let quoted = Self.quote(object.name)
        let columnsResult = try await connection.query("PRAGMA table_info(\(quoted));", params: nil)
        let columns: [TableColumn] = columnsResult.rows.enumerated().map { idx, row in
            // PRAGMA table_info: cid, name, type, notnull, dflt_value, pk
            TableColumn(
                name: SchemaRowDecoder.string(row, at: 1) ?? "",
                dataType: SchemaRowDecoder.string(row, at: 2) ?? "",
                isNullable: SchemaRowDecoder.int(row, at: 3) != 1,
                isPrimaryKey: (SchemaRowDecoder.int(row, at: 5) ?? 0) > 0,
                defaultValue: SchemaRowDecoder.string(row, at: 4),
                position: SchemaRowDecoder.int(row, at: 0) ?? idx
            )
        }

        // 索引：PRAGMA index_list + 每个 index 的 index_info
        var indexes: [TableIndex] = []
        let indexList = try? await connection.query("PRAGMA index_list(\(quoted));", params: nil)
        if let indexList {
            for row in indexList.rows {
                // PRAGMA index_list: seq, name, unique, origin, partial
                guard let indexName = SchemaRowDecoder.string(row, at: 1) else { continue }
                let isUnique = SchemaRowDecoder.int(row, at: 2) == 1
                let colsResult = (try? await connection.query("PRAGMA index_info(\"\(Self.escape(indexName))\");", params: nil)) ?? QueryResult(columns: [], rows: [], rowsAffected: 0)
                let cols = colsResult.rows.compactMap { SchemaRowDecoder.string($0, at: 2) }
                indexes.append(TableIndex(name: indexName, columns: cols, isUnique: isUnique, indexType: nil))
            }
        }

        // 外键：PRAGMA foreign_key_list
        var foreignKeys: [ForeignKey] = []
        let fkList = try? await connection.query("PRAGMA foreign_key_list(\(quoted));", params: nil)
        if let fkList {
            for row in fkList.rows {
                // PRAGMA foreign_key_list: id, seq, table, from, to, on_update, on_delete, match
                guard let name = SchemaRowDecoder.string(row, at: 3) else { continue }
                let refTable = SchemaRowDecoder.string(row, at: 2) ?? ""
                let refCol = SchemaRowDecoder.string(row, at: 4) ?? ""
                foreignKeys.append(ForeignKey(
                    name: "fk_\(object.name)_\(name)",
                    columns: [name],
                    referencesTable: refTable,
                    referencesColumns: refCol.isEmpty ? [] : [refCol],
                    onDelete: SchemaRowDecoder.string(row, at: 6),
                    onUpdate: SchemaRowDecoder.string(row, at: 5)
                ))
            }
        }

        // 触发器
        let triggerSql = "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='\(Self.escape(object.name))' ORDER BY name;"
        let triggerResult = (try? await connection.query(triggerSql, params: nil)) ?? QueryResult(columns: [], rows: [], rowsAffected: 0)
        let triggers: [TableTrigger] = triggerResult.rows.compactMap { row in
            guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
            return TableTrigger(name: name, timing: nil, event: nil, statement: nil)
        }

        let ddl = try? await loadDDL(for: object, in: connection)
        return TableSchema(
            table: object,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            triggers: triggers,
            ddl: ddl
        )
    }

    public func loadDDL(for object: DatabaseObject, in connection: any DatabaseConnection) async throws -> String? {
        let sql = "SELECT sql FROM sqlite_master WHERE type='\(object.kind == .view ? "view" : "table")' AND name='\(Self.escape(object.name))' LIMIT 1;"
        let result = try await connection.query(sql, params: nil)
        guard let row = result.rows.first else { return nil }
        return SchemaRowDecoder.string(row, at: 0)
    }

    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "'", with: "''")
    }

    private static func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

// MARK: - MySQL

/// MySQL 自省：基于 `information_schema` 与 `SHOW`。
public struct MySQLIntrospector: DatabaseIntrospector {
    public init() {}

    public func loadDatabases(in connection: any DatabaseConnection) async throws -> [String] {
        let result = try await connection.query("SHOW DATABASES;", params: nil)
        return result.rows.compactMap { SchemaRowDecoder.string($0, at: 0) }
            .filter { !$0.isEmpty && $0 != "information_schema" && $0 != "performance_schema" && $0 != "mysql" && $0 != "sys" }
    }

    public func loadSchemas(in connection: any DatabaseConnection, database: String?) async throws -> [String] {
        // MySQL 中 schema ≈ database，这里返回单元素，避免树出现冗余层级。
        database.map { [$0] } ?? []
    }

    public func loadObjects(
        of kind: DatabaseObjectKind,
        in connection: any DatabaseConnection,
        database: String?,
        schema: String?
    ) async throws -> [DatabaseObject] {
        guard let database else { return [] }
        switch kind {
        case .table, .view:
            let tableType = kind == .table ? "BASE TABLE" : "VIEW"
            let sql = """
            SELECT table_name, table_comment FROM information_schema.tables
            WHERE table_schema = '\(Self.escape(database))' AND table_type = '\(tableType)'
            ORDER BY table_name;
            """
            let result = try await connection.query(sql, params: nil)
            return result.rows.compactMap { row in
                guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
                let comment = SchemaRowDecoder.string(row, at: 1)
                return DatabaseObject(kind: kind, name: name, database: database, comment: (comment?.isEmpty == false ? comment : nil))
            }
        case .procedure, .function:
            let routineType = kind == .procedure ? "PROCEDURE" : "FUNCTION"
            let sql = """
            SELECT routine_name FROM information_schema.routines
            WHERE routine_schema = '\(Self.escape(database))' AND routine_type = '\(routineType)'
            ORDER BY routine_name;
            """
            let result = try await connection.query(sql, params: nil)
            return result.rows.compactMap { row in
                guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
                return DatabaseObject(kind: kind, name: name, database: database)
            }
        case .index, .trigger, .materializedView:
            // 索引/触发器随表结构展示，不在顶层树列出。Phase 5 可扩展。
            return []
        }
    }

    public func describeTable(_ object: DatabaseObject, in connection: any DatabaseConnection) async throws -> TableSchema {
        guard let database = object.database else {
            return TableSchema(table: object, columns: [])
        }
        // column_type 带长度/精度修饰符（如 tinyint(1)、varchar(255)）；
        // data_type 只有裸类型名，会丢掉 MySQL 用 tinyint(1) 表示 BOOLEAN 的约定。
        let sql = """
        SELECT column_name, column_type, is_nullable, column_default, column_key, column_comment, ordinal_position
        FROM information_schema.columns
        WHERE table_schema = '\(Self.escape(database))' AND table_name = '\(Self.escape(object.name))'
        ORDER BY ordinal_position;
        """
        let result = try await connection.query(sql, params: nil)
        let columns: [TableColumn] = result.rows.map { row in
            let dataType = SchemaRowDecoder.string(row, at: 1) ?? ""
            return TableColumn(
                name: SchemaRowDecoder.string(row, at: 0) ?? "",
                dataType: dataType,
                isNullable: SchemaRowDecoder.string(row, at: 2)?.uppercased() == "YES",
                isPrimaryKey: SchemaRowDecoder.string(row, at: 4)?.uppercased() == "PRI",
                defaultValue: SchemaRowDecoder.string(row, at: 3),
                position: (SchemaRowDecoder.int(row, at: 6) ?? 1) - 1,
                comment: SchemaRowDecoder.string(row, at: 5),
                enumValues: mysqlEnumValues(in: dataType)
            )
        }
        let indexes = await Self.indexes(in: connection, database: database, table: object.name)
        let foreignKeys = await Self.foreignKeys(in: connection, database: database, table: object.name)
        let triggers = await Self.triggers(in: connection, database: database, table: object.name)
        let ddl = try? await loadDDL(for: object, in: connection)
        return TableSchema(
            table: object,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            triggers: triggers,
            ddl: ddl
        )
    }

    /// information_schema.statistics 按索引名聚合列（seq_in_index 排序）。
    private static func indexes(in connection: any DatabaseConnection, database: String, table: String) async -> [TableIndex] {
        let sql = """
        SELECT index_name, non_unique, seq_in_index, column_name, index_type
        FROM information_schema.statistics
        WHERE table_schema = '\(escape(database))' AND table_name = '\(escape(table))'
        ORDER BY index_name, seq_in_index;
        """
        guard let result = try? await connection.query(sql, params: nil) else { return [] }
        var order: [String] = []
        var grouped: [String: (isUnique: Bool, columns: [String], indexType: String?)] = [:]
        for row in result.rows {
            guard let name = SchemaRowDecoder.string(row, at: 0),
                  let column = SchemaRowDecoder.string(row, at: 3) else { continue }
            let isUnique = SchemaRowDecoder.int(row, at: 1) == 0
            if grouped[name] == nil {
                order.append(name)
                grouped[name] = (isUnique, [], SchemaRowDecoder.string(row, at: 4))
            }
            grouped[name]?.columns.append(column)
        }
        return order.compactMap { name in
            guard let entry = grouped[name] else { return nil }
            return TableIndex(name: name, columns: entry.columns, isUnique: entry.isUnique, indexType: entry.indexType)
        }
    }

    /// 外键：key_column_usage 提供列映射，referential_constraints 提供级联规则。
    private static func foreignKeys(in connection: any DatabaseConnection, database: String, table: String) async -> [ForeignKey] {
        let sql = """
        SELECT kcu.constraint_name, kcu.column_name, kcu.referenced_table_name,
               kcu.referenced_column_name, rc.delete_rule, rc.update_rule
        FROM information_schema.key_column_usage kcu
        JOIN information_schema.referential_constraints rc
          ON rc.constraint_schema = kcu.table_schema
         AND rc.constraint_name = kcu.constraint_name
         AND rc.table_name = kcu.table_name
        WHERE kcu.table_schema = '\(escape(database))' AND kcu.table_name = '\(escape(table))'
          AND kcu.referenced_table_name IS NOT NULL
        ORDER BY kcu.constraint_name, kcu.ordinal_position;
        """
        guard let result = try? await connection.query(sql, params: nil) else { return [] }
        var order: [String] = []
        var grouped: [String: ForeignKey] = [:]
        for row in result.rows {
            guard let name = SchemaRowDecoder.string(row, at: 0),
                  let column = SchemaRowDecoder.string(row, at: 1),
                  let refTable = SchemaRowDecoder.string(row, at: 2),
                  let refColumn = SchemaRowDecoder.string(row, at: 3) else { continue }
            if var existing = grouped[name] {
                existing = ForeignKey(
                    name: name,
                    columns: existing.columns + [column],
                    referencesTable: refTable,
                    referencesColumns: existing.referencesColumns + [refColumn],
                    onDelete: existing.onDelete,
                    onUpdate: existing.onUpdate
                )
                grouped[name] = existing
            } else {
                order.append(name)
                grouped[name] = ForeignKey(
                    name: name,
                    columns: [column],
                    referencesTable: refTable,
                    referencesColumns: [refColumn],
                    onDelete: SchemaRowDecoder.string(row, at: 4),
                    onUpdate: SchemaRowDecoder.string(row, at: 5)
                )
            }
        }
        return order.compactMap { grouped[$0] }
    }

    private static func triggers(in connection: any DatabaseConnection, database: String, table: String) async -> [TableTrigger] {
        let sql = """
        SELECT trigger_name, action_timing, event_manipulation, action_statement
        FROM information_schema.triggers
        WHERE trigger_schema = '\(escape(database))' AND event_object_table = '\(escape(table))'
        ORDER BY trigger_name;
        """
        guard let result = try? await connection.query(sql, params: nil) else { return [] }
        return result.rows.compactMap { row in
            guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
            return TableTrigger(
                name: name,
                timing: SchemaRowDecoder.string(row, at: 1),
                event: SchemaRowDecoder.string(row, at: 2),
                statement: SchemaRowDecoder.string(row, at: 3)
            )
        }
    }

    public func loadDDL(for object: DatabaseObject, in connection: any DatabaseConnection) async throws -> String? {
        guard let database = object.database else { return nil }
        let qualified = "`\(Self.escape(database))`.`\(Self.escape(object.name))`"
        switch object.kind {
        case .table:
            let result = try await connection.query("SHOW CREATE TABLE \(qualified);", params: nil)
            return result.rows.first.flatMap { SchemaRowDecoder.string($0, at: 1) }
        case .view:
            let result = try await connection.query("SHOW CREATE VIEW \(qualified);", params: nil)
            return result.rows.first.flatMap { SchemaRowDecoder.string($0, at: 1) }
        case .procedure:
            let result = try await connection.query("SHOW CREATE PROCEDURE \(qualified);", params: nil)
            return result.rows.first.flatMap { SchemaRowDecoder.string($0, at: 2) }
        case .function:
            let result = try await connection.query("SHOW CREATE FUNCTION \(qualified);", params: nil)
            return result.rows.first.flatMap { SchemaRowDecoder.string($0, at: 2) }
        case .trigger:
            let result = try await connection.query("SHOW CREATE TRIGGER \(qualified);", params: nil)
            return result.rows.first.flatMap { SchemaRowDecoder.string($0, at: 2) }
        case .index, .materializedView:
            return nil
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "``").replacingOccurrences(of: "'", with: "''")
    }
}

// MARK: - PostgreSQL

/// PostgreSQL 自省：基于 `information_schema` 与 `pg_catalog`。
public struct PostgreSQLIntrospector: DatabaseIntrospector {
    public init() {}

    public func loadDatabases(in connection: any DatabaseConnection) async throws -> [String] {
        let result = try await connection.query(
            "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;",
            params: nil
        )
        return result.rows.compactMap { SchemaRowDecoder.string($0, at: 0) }
    }

    public func loadSchemas(in connection: any DatabaseConnection, database: String?) async throws -> [String] {
        let result = try await connection.query(
            """
            SELECT schema_name FROM information_schema.schemata
            WHERE schema_name NOT LIKE 'pg_%' AND schema_name <> 'information_schema'
            ORDER BY schema_name;
            """,
            params: nil
        )
        return result.rows.compactMap { SchemaRowDecoder.string($0, at: 0) }
    }

    public func loadObjects(
        of kind: DatabaseObjectKind,
        in connection: any DatabaseConnection,
        database: String?,
        schema: String?
    ) async throws -> [DatabaseObject] {
        switch kind {
        case .table, .view, .materializedView:
            let tableType: String
            switch kind {
            case .table: tableType = "BASE TABLE"
            case .view: tableType = "VIEW"
            default: tableType = "FOREIGN"  // 占位，物化视图走 pg_class 分支
            }
            if kind == .materializedView {
                let schemaPredicate = schema.map { "n.nspname = '\(Self.escape($0))'" } ?? "n.nspname = current_schema()"
                let sql = """
                SELECT relname, n.nspname FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind = 'm' AND \(schemaPredicate)
                ORDER BY relname;
                """
                let result = try await connection.query(sql, params: nil)
                return result.rows.compactMap { row in
                    guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
                    return DatabaseObject(kind: kind, name: name, database: database, schema: SchemaRowDecoder.string(row, at: 1) ?? schema)
                }
            }
            let schemaPredicate = schema.map { "table_schema = '\(Self.escape($0))'" } ?? "table_schema = current_schema()"
            let sql = """
            SELECT table_name, table_schema FROM information_schema.tables
            WHERE \(schemaPredicate) AND table_type = '\(tableType)'
            ORDER BY table_name;
            """
            let result = try await connection.query(sql, params: nil)
            return result.rows.compactMap { row in
                guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
                return DatabaseObject(kind: kind, name: name, database: database, schema: SchemaRowDecoder.string(row, at: 1) ?? schema)
            }
        case .procedure, .function:
            let kindFilter = kind == .procedure ? "p" : "f"
            let schemaPredicate = schema.map { "n.nspname = '\(Self.escape($0))'" } ?? "n.nspname = current_schema()"
            let sql = """
            SELECT p.proname, n.nspname FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE \(schemaPredicate) AND p.prokind = '\(kindFilter)'
            ORDER BY p.proname;
            """
            let result = try await connection.query(sql, params: nil)
            return result.rows.compactMap { row in
                guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
                return DatabaseObject(kind: kind, name: name, database: database, schema: SchemaRowDecoder.string(row, at: 1) ?? schema)
            }
        case .index, .trigger:
            return []  // 随表结构展示
        }
    }

    public func describeTable(_ object: DatabaseObject, in connection: any DatabaseConnection) async throws -> TableSchema {
        let schema = object.schema ?? "public"
        let sql = """
        SELECT column_name, data_type, is_nullable, column_default, ordinal_position, udt_name
        FROM information_schema.columns
        WHERE table_schema = '\(Self.escape(schema))' AND table_name = '\(Self.escape(object.name))'
        ORDER BY ordinal_position;
        """
        let result = try await connection.query(sql, params: nil)
        // 主键列
        let pkResult = (try? await connection.query(
            """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = '\(Self.escape(schema))'
              AND tc.table_name = '\(Self.escape(object.name))';
            """,
            params: nil)) ?? QueryResult(columns: [], rows: [], rowsAffected: 0)
        let pkColumns = Set(pkResult.rows.compactMap { SchemaRowDecoder.string($0, at: 0) })

        var columns: [TableColumn] = result.rows.map { row in
            TableColumn(
                name: SchemaRowDecoder.string(row, at: 0) ?? "",
                dataType: SchemaRowDecoder.string(row, at: 1) ?? "",
                isNullable: SchemaRowDecoder.string(row, at: 2)?.uppercased() == "YES",
                isPrimaryKey: pkColumns.contains(SchemaRowDecoder.string(row, at: 0) ?? ""),
                defaultValue: SchemaRowDecoder.string(row, at: 3),
                position: (SchemaRowDecoder.int(row, at: 4) ?? 1) - 1
            )
        }
        // enum 列的 data_type 只报 USER-DEFINED；取值需按 udt_name 查 pg_enum。
        if columns.contains(where: { $0.dataType.uppercased() == "USER-DEFINED" }) {
            let enumLabels = await Self.enumLabelsByType(in: connection, schema: schema)
            for index in columns.indices where columns[index].dataType.uppercased() == "USER-DEFINED" {
                let udt = SchemaRowDecoder.string(result.rows[index], at: 5) ?? ""
                if let labels = enumLabels[udt], !labels.isEmpty {
                    columns[index].enumValues = labels
                }
            }
        }
        let indexes = await Self.indexes(in: connection, schema: schema, table: object.name)
        let foreignKeys = await Self.foreignKeys(in: connection, schema: schema, table: object.name)
        let triggers = await Self.triggers(in: connection, schema: schema, table: object.name)
        let ddl = try? await loadDDL(for: object, in: connection)
        return TableSchema(
            table: object,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            triggers: triggers,
            ddl: ddl
        )
    }

    /// pg_index + pg_get_indexdef 逐键取列名/表达式，聚合为表索引。
    /// int2vector::int[] 是 0 基数组（generate_subscripts 从 0 起），
    /// 而 pg_get_indexdef 的列号参数是 1 起，故 +1。
    private static func indexes(in connection: any DatabaseConnection, schema: String, table: String) async -> [TableIndex] {
        let sql = """
        SELECT i.relname, ix.indisunique, am.amname, pg_get_indexdef(ix.indexrelid, k.ord + 1, false)
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am am ON am.oid = i.relam
        CROSS JOIN LATERAL generate_subscripts(ix.indkey::int[], 1) AS k(ord)
        WHERE n.nspname = '\(escape(schema))' AND t.relname = '\(escape(table))'
        ORDER BY i.relname, k.ord;
        """
        guard let result = try? await connection.query(sql, params: nil) else { return [] }
        var order: [String] = []
        var grouped: [String: (isUnique: Bool, columns: [String], indexType: String?)] = [:]
        for row in result.rows {
            guard let name = SchemaRowDecoder.string(row, at: 0),
                  let column = SchemaRowDecoder.string(row, at: 3) else { continue }
            if grouped[name] == nil {
                order.append(name)
                grouped[name] = (
                    SchemaRowDecoder.string(row, at: 1) == "true",
                    [],
                    SchemaRowDecoder.string(row, at: 2)
                )
            }
            grouped[name]?.columns.append(column)
        }
        return order.compactMap { name in
            guard let entry = grouped[name] else { return nil }
            return TableIndex(name: name, columns: entry.columns, isUnique: entry.isUnique, indexType: entry.indexType)
        }
    }

    /// pg_constraint 外键：conkey/confkey 逐位展开为列名对，级联规则按代码映射。
    private static func foreignKeys(in connection: any DatabaseConnection, schema: String, table: String) async -> [ForeignKey] {
        let sql = """
        SELECT con.conname, sa.attname, ta.attname, conf.relname, con.confdeltype, con.confupdtype
        FROM pg_constraint con
        JOIN pg_class t ON t.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_class conf ON conf.oid = con.confrelid
        CROSS JOIN LATERAL generate_subscripts(con.conkey::int[], 1) AS k(ord)
        JOIN pg_attribute sa ON sa.attrelid = con.conrelid AND sa.attnum = con.conkey[k.ord]
        JOIN pg_attribute ta ON ta.attrelid = con.confrelid AND ta.attnum = con.confkey[k.ord]
        WHERE con.contype = 'f' AND n.nspname = '\(escape(schema))' AND t.relname = '\(escape(table))'
        ORDER BY con.conname, k.ord;
        """
        guard let result = try? await connection.query(sql, params: nil) else { return [] }
        var order: [String] = []
        var grouped: [String: ForeignKey] = [:]
        for row in result.rows {
            guard let name = SchemaRowDecoder.string(row, at: 0),
                  let column = SchemaRowDecoder.string(row, at: 1),
                  let refColumn = SchemaRowDecoder.string(row, at: 2),
                  let refTable = SchemaRowDecoder.string(row, at: 3) else { continue }
            if var existing = grouped[name] {
                existing = ForeignKey(
                    name: name,
                    columns: existing.columns + [column],
                    referencesTable: refTable,
                    referencesColumns: existing.referencesColumns + [refColumn],
                    onDelete: existing.onDelete,
                    onUpdate: existing.onUpdate
                )
                grouped[name] = existing
            } else {
                order.append(name)
                grouped[name] = ForeignKey(
                    name: name,
                    columns: [column],
                    referencesTable: refTable,
                    referencesColumns: [refColumn],
                    onDelete: fkAction(SchemaRowDecoder.string(row, at: 4)),
                    onUpdate: fkAction(SchemaRowDecoder.string(row, at: 5))
                )
            }
        }
        return order.compactMap { grouped[$0] }
    }

    /// pg_constraint 的 confdeltype/confupdtype 单字符代码 → SQL 动作。
    private static func fkAction(_ code: String?) -> String? {
        switch code {
        case "a": return "NO ACTION"
        case "r": return "RESTRICT"
        case "c": return "CASCADE"
        case "n": return "SET NULL"
        case "d": return "SET DEFAULT"
        default: return nil
        }
    }

    /// 用户触发器（排除内部约束触发器）；tgtype 位标志解析时机/事件。
    private static func triggers(in connection: any DatabaseConnection, schema: String, table: String) async -> [TableTrigger] {
        let sql = """
        SELECT tg.tgname, tg.tgtype, tg.tgenabled, pg_get_triggerdef(tg.oid)
        FROM pg_trigger tg
        JOIN pg_class t ON t.oid = tg.tgrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE NOT tg.tgisinternal AND n.nspname = '\(escape(schema))' AND t.relname = '\(escape(table))'
        ORDER BY tg.tgname;
        """
        guard let result = try? await connection.query(sql, params: nil) else { return [] }
        return result.rows.compactMap { row in
            guard let name = SchemaRowDecoder.string(row, at: 0) else { return nil }
            let type = SchemaRowDecoder.int(row, at: 1) ?? 0
            let timing: String
            if type & 64 != 0 {
                timing = "INSTEAD OF"
            } else if type & 2 != 0 {
                timing = "BEFORE"
            } else {
                timing = "AFTER"
            }
            var events: [String] = []
            if type & 4 != 0 { events.append("INSERT") }
            if type & 8 != 0 { events.append("DELETE") }
            if type & 16 != 0 { events.append("UPDATE") }
            if type & 32 != 0 { events.append("TRUNCATE") }
            return TableTrigger(
                name: name,
                timing: timing,
                event: events.isEmpty ? nil : events.joined(separator: " OR "),
                statement: SchemaRowDecoder.string(row, at: 3),
                isEnabled: SchemaRowDecoder.string(row, at: 2) != "D"
            )
        }
    }

    /// 当前 schema 下全部 enum 类型的取值（按 enumsortorder），以类型名为键。
    private static func enumLabelsByType(in connection: any DatabaseConnection, schema: String) async -> [String: [String]] {
        let sql = """
        SELECT t.typname, e.enumlabel
        FROM pg_enum e
        JOIN pg_type t ON e.enumtypid = t.oid
        JOIN pg_namespace n ON t.typnamespace = n.oid
        WHERE n.nspname = '\(escape(schema))'
        ORDER BY t.typname, e.enumsortorder;
        """
        guard let result = try? await connection.query(sql, params: nil) else { return [:] }
        var labels: [String: [String]] = [:]
        for row in result.rows {
            guard let type = SchemaRowDecoder.string(row, at: 0),
                  let label = SchemaRowDecoder.string(row, at: 1) else { continue }
            labels[type, default: []].append(label)
        }
        return labels
    }

    public func loadDDL(for object: DatabaseObject, in connection: any DatabaseConnection) async throws -> String? {
        let schema = object.schema ?? "public"
        switch object.kind {
        case .table:
            return await Self.tableDDL(name: object.name, schema: schema, in: connection)
        case .view, .materializedView:
            let sql = """
            SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname), pg_get_viewdef(c.oid, true)
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(Self.escape(schema))' AND c.relname = '\(Self.escape(object.name))'
              AND c.relkind IN ('v', 'm');
            """
            guard let row = try await connection.query(sql, params: nil).rows.first,
                  let qualified = SchemaRowDecoder.string(row, at: 0),
                  var definition = SchemaRowDecoder.string(row, at: 1) else { return nil }
            definition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
            if definition.hasSuffix(";") { definition.removeLast() }
            let keyword = object.kind == .materializedView ? "MATERIALIZED VIEW" : "VIEW"
            return "CREATE \(keyword) \(qualified) AS\n\(definition);"
        case .procedure, .function:
            let kindFilter = object.kind == .procedure ? "p" : "f"
            let sql = """
            SELECT pg_get_functiondef(p.oid)
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = '\(Self.escape(schema))' AND p.proname = '\(Self.escape(object.name))'
              AND p.prokind = '\(kindFilter)'
            LIMIT 1;
            """
            return try await connection.query(sql, params: nil).rows.first.flatMap { SchemaRowDecoder.string($0, at: 0) }
        case .index:
            let sql = """
            SELECT pg_get_indexdef(c.oid)
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(Self.escape(schema))' AND c.relname = '\(Self.escape(object.name))'
              AND c.relkind = 'i';
            """
            return try await connection.query(sql, params: nil).rows.first.flatMap { SchemaRowDecoder.string($0, at: 0) }
        case .trigger:
            let sql = """
            SELECT pg_get_triggerdef(tg.oid)
            FROM pg_trigger tg
            JOIN pg_class c ON c.oid = tg.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(Self.escape(schema))' AND tg.tgname = '\(Self.escape(object.name))'
              AND NOT tg.tgisinternal
            LIMIT 1;
            """
            return try await connection.query(sql, params: nil).rows.first.flatMap { SchemaRowDecoder.string($0, at: 0) }
        }
    }

    /// 从 catalog 拼装 CREATE TABLE：列（类型/默认值/identity/generated/NOT NULL）+
    /// 约束（pg_get_constraintdef）+ 非约束索引（pg_get_indexdef）。
    /// 不依赖 pg_get_tabledef 等扩展，原生 PostgreSQL 即可用。
    private static func tableDDL(name: String, schema: String, in connection: any DatabaseConnection) async -> String? {
        let predicate = "n.nspname = '\(escape(schema))' AND c.relname = '\(escape(name))'"
        let headerSQL = """
        SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE \(predicate) AND c.relkind IN ('r', 'p');
        """
        guard let headerRow = try? await connection.query(headerSQL, params: nil).rows.first,
              let qualified = SchemaRowDecoder.string(headerRow, at: 0) else { return nil }

        let columnsSQL = """
        SELECT quote_ident(a.attname), format_type(a.atttypid, a.atttypmod), a.attnotnull,
               pg_get_expr(ad.adbin, ad.adrelid), a.attidentity, a.attgenerated
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        WHERE \(predicate) AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum;
        """
        guard let columnRows = try? await connection.query(columnsSQL, params: nil).rows, !columnRows.isEmpty else { return nil }
        var lines: [String] = columnRows.compactMap { row in
            guard let columnName = SchemaRowDecoder.string(row, at: 0),
                  let typeName = SchemaRowDecoder.string(row, at: 1) else { return nil }
            var line = "    \(columnName) \(typeName)"
            let defaultValue = SchemaRowDecoder.string(row, at: 3)
            let identity = SchemaRowDecoder.string(row, at: 4) ?? ""
            let generated = SchemaRowDecoder.string(row, at: 5) ?? ""
            if generated == "s", let expression = defaultValue {
                line += " GENERATED ALWAYS AS (\(expression)) STORED"
            } else if identity == "a" {
                line += " GENERATED ALWAYS AS IDENTITY"
            } else if identity == "d" {
                line += " GENERATED BY DEFAULT AS IDENTITY"
            } else if let defaultValue {
                line += " DEFAULT \(defaultValue)"
            }
            if SchemaRowDecoder.string(row, at: 2) == "true" {
                line += " NOT NULL"
            }
            return line
        }

        let constraintsSQL = """
        SELECT quote_ident(con.conname), pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE \(predicate) AND con.contype IN ('p', 'u', 'f', 'c')
        ORDER BY CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'f' THEN 2 ELSE 3 END, con.conname;
        """
        if let constraintRows = try? await connection.query(constraintsSQL, params: nil).rows {
            for row in constraintRows {
                guard let constraintName = SchemaRowDecoder.string(row, at: 0),
                      let definition = SchemaRowDecoder.string(row, at: 1) else { continue }
                lines.append("    CONSTRAINT \(constraintName) \(definition)")
            }
        }

        var ddl = "CREATE TABLE \(qualified) (\n" + lines.joined(separator: ",\n") + "\n);"

        let indexesSQL = """
        SELECT pg_get_indexdef(i.oid)
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_class c ON c.oid = ix.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE \(predicate)
          AND NOT EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid = ix.indexrelid)
        ORDER BY i.relname;
        """
        if let indexRows = try? await connection.query(indexesSQL, params: nil).rows {
            for row in indexRows {
                guard let definition = SchemaRowDecoder.string(row, at: 0) else { continue }
                ddl += "\n\n\(definition);"
            }
        }
        return ddl
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}
