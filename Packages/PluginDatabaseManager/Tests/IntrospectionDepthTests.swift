import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P4-4：MySQL/PG introspection 深度。
// 断言 Inspector 所需的索引/外键/触发器/DDL 在真实引擎上完整可得，
// PG 的 DDL 必须由 catalog 自行拼装（不依赖 pg_get_tabledef 扩展）。

@Suite(.serialized)
struct IntrospectionDepthTests {
    // MARK: - MySQL

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"] != nil))
    func mysqlDescribeTableReportsIndexesForeignKeysAndTriggers() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"].flatMap(Int.init))
        let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await conn.close() } }
        _ = try await conn.execute("DROP TABLE IF EXISTS si_depth_child", params: nil)
        _ = try await conn.execute("DROP TABLE IF EXISTS si_depth_parent", params: nil)
        _ = try await conn.execute("CREATE TABLE si_depth_parent (id INTEGER PRIMARY KEY)", params: nil)
        _ = try await conn.execute("""
        CREATE TABLE si_depth_child (
            id INTEGER PRIMARY KEY,
            parent_id INTEGER,
            email VARCHAR(128),
            CONSTRAINT fk_depth_child_parent FOREIGN KEY (parent_id)
                REFERENCES si_depth_parent(id) ON DELETE CASCADE ON UPDATE RESTRICT,
            UNIQUE KEY uq_depth_email (email),
            KEY idx_depth_parent (parent_id)
        )
        """, params: nil)
        _ = try await conn.execute("""
        CREATE TRIGGER trg_depth_child_bi BEFORE INSERT ON si_depth_child
        FOR EACH ROW SET NEW.email = LOWER(NEW.email)
        """, params: nil)
        defer {
            Task {
                _ = try? await conn.execute("DROP TABLE IF EXISTS si_depth_child", params: nil)
                _ = try? await conn.execute("DROP TABLE IF EXISTS si_depth_parent", params: nil)
            }
        }

        let schema = try await MySQLIntrospector().describeTable(
            DatabaseObject(kind: .table, name: "si_depth_child", database: "testdb"), in: conn)

        let unique = try #require(schema.indexes.first { $0.name == "uq_depth_email" })
        #expect(unique.isUnique)
        #expect(unique.columns == ["email"])
        let plain = try #require(schema.indexes.first { $0.name == "idx_depth_parent" })
        #expect(plain.isUnique == false)
        #expect(plain.columns == ["parent_id"])
        #expect(schema.indexes.contains { $0.name == "PRIMARY" && $0.isUnique })

        let fk = try #require(schema.foreignKeys.first { $0.name == "fk_depth_child_parent" })
        #expect(fk.columns == ["parent_id"])
        #expect(fk.referencesTable == "si_depth_parent")
        #expect(fk.referencesColumns == ["id"])
        #expect(fk.onDelete?.uppercased() == "CASCADE")
        #expect(fk.onUpdate?.uppercased() == "RESTRICT")

        let trigger = try #require(schema.triggers.first { $0.name == "trg_depth_child_bi" })
        #expect(trigger.timing?.uppercased() == "BEFORE")
        #expect(trigger.event?.uppercased() == "INSERT")
        #expect(trigger.statement?.contains("LOWER") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"] != nil))
    func mysqlLoadDDLDispatchesByObjectKind() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"].flatMap(Int.init))
        let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await conn.close() } }
        // binlog 开启时创建 FUNCTION 需要该全局开关（root 可设）。
        _ = try? await conn.execute("SET GLOBAL log_bin_trust_function_creators = 1", params: nil)
        _ = try await conn.execute("DROP VIEW IF EXISTS si_depth2_view", params: nil)
        _ = try await conn.execute("DROP PROCEDURE IF EXISTS si_depth2_proc", params: nil)
        _ = try await conn.execute("DROP FUNCTION IF EXISTS si_depth2_fn", params: nil)
        _ = try await conn.execute("DROP TABLE IF EXISTS si_depth_child", params: nil)
        _ = try await conn.execute("DROP TABLE IF EXISTS si_depth2_parent", params: nil)
        _ = try await conn.execute("CREATE TABLE si_depth2_parent (id INTEGER PRIMARY KEY)", params: nil)
        _ = try await conn.execute("CREATE VIEW si_depth2_view AS SELECT id FROM si_depth2_parent", params: nil)
        _ = try await conn.execute("CREATE PROCEDURE si_depth2_proc() BEGIN SELECT 1; END", params: nil)
        _ = try await conn.execute("CREATE FUNCTION si_depth2_fn() RETURNS INT DETERMINISTIC RETURN 42", params: nil)
        defer {
            Task {
                _ = try? await conn.execute("DROP VIEW IF EXISTS si_depth2_view", params: nil)
                _ = try? await conn.execute("DROP PROCEDURE IF EXISTS si_depth2_proc", params: nil)
                _ = try? await conn.execute("DROP FUNCTION IF EXISTS si_depth2_fn", params: nil)
                _ = try? await conn.execute("DROP TABLE IF EXISTS si_depth2_parent", params: nil)
            }
        }

        let introspector = MySQLIntrospector()
        let viewDDL = try await introspector.loadDDL(
            for: DatabaseObject(kind: .view, name: "si_depth2_view", database: "testdb"), in: conn)
        #expect(viewDDL?.uppercased().contains("VIEW") == true)
        #expect(viewDDL?.contains("si_depth2_parent") == true)

        let procDDL = try await introspector.loadDDL(
            for: DatabaseObject(kind: .procedure, name: "si_depth2_proc", database: "testdb"), in: conn)
        #expect(procDDL?.uppercased().contains("PROCEDURE") == true)

        let fnDDL = try await introspector.loadDDL(
            for: DatabaseObject(kind: .function, name: "si_depth2_fn", database: "testdb"), in: conn)
        #expect(fnDDL?.uppercased().contains("FUNCTION") == true)
        #expect(fnDDL?.contains("42") == true)
    }

    // MARK: - PostgreSQL

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_PG_PORT"] != nil))
    func pgDescribeTableReportsIndexesForeignKeysAndTriggersInCustomSchema() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LODE_TEST_PG_PORT"].flatMap(Int.init))
        let conn = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await conn.close() } }
        _ = try await conn.execute("DROP SCHEMA IF EXISTS si_depth CASCADE", params: nil)
        _ = try await conn.execute("CREATE SCHEMA si_depth", params: nil)
        _ = try await conn.execute("CREATE TABLE si_depth.parent (id INTEGER PRIMARY KEY)", params: nil)
        _ = try await conn.execute("""
        CREATE TABLE si_depth.child (
            id INTEGER PRIMARY KEY,
            parent_id INTEGER REFERENCES si_depth.parent(id) ON DELETE CASCADE,
            email TEXT UNIQUE,
            note TEXT
        )
        """, params: nil)
        _ = try await conn.execute("CREATE INDEX idx_depth_note ON si_depth.child (note)", params: nil)
        _ = try await conn.execute("""
        CREATE FUNCTION si_depth.lower_email() RETURNS trigger AS $$
        BEGIN NEW.email := lower(NEW.email); RETURN NEW; END
        $$ LANGUAGE plpgsql
        """, params: nil)
        _ = try await conn.execute("""
        CREATE TRIGGER trg_depth_child_bi BEFORE INSERT ON si_depth.child
        FOR EACH ROW EXECUTE FUNCTION si_depth.lower_email()
        """, params: nil)
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS si_depth CASCADE", params: nil) } }

        let schema = try await PostgreSQLIntrospector().describeTable(
            DatabaseObject(kind: .table, name: "child", database: "testdb", schema: "si_depth"), in: conn)

        let unique = try #require(schema.indexes.first { $0.columns == ["email"] })
        #expect(unique.isUnique)
        let plain = try #require(schema.indexes.first { $0.name == "idx_depth_note" })
        #expect(plain.isUnique == false)
        #expect(plain.columns == ["note"])
        #expect(plain.indexType?.lowercased() == "btree")
        #expect(schema.indexes.contains { $0.columns == ["id"] && $0.isUnique })

        let fk = try #require(schema.foreignKeys.first)
        #expect(fk.columns == ["parent_id"])
        #expect(fk.referencesTable == "parent")
        #expect(fk.referencesColumns == ["id"])
        #expect(fk.onDelete?.uppercased() == "CASCADE")

        let trigger = try #require(schema.triggers.first { $0.name == "trg_depth_child_bi" })
        #expect(trigger.timing?.uppercased() == "BEFORE")
        #expect(trigger.event?.uppercased() == "INSERT")
        #expect(trigger.statement?.contains("lower") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_PG_PORT"] != nil))
    func pgLoadDDLAssemblesTableFromCatalogWithoutExtension() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LODE_TEST_PG_PORT"].flatMap(Int.init))
        let conn = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await conn.close() } }
        _ = try await conn.execute("DROP SCHEMA IF EXISTS si_depth_ddl CASCADE", params: nil)
        _ = try await conn.execute("CREATE SCHEMA si_depth_ddl", params: nil)
        _ = try await conn.execute("CREATE TABLE si_depth_ddl.parent (id INTEGER PRIMARY KEY)", params: nil)
        _ = try await conn.execute("""
        CREATE TABLE si_depth_ddl.child (
            id INTEGER PRIMARY KEY,
            parent_id INTEGER REFERENCES si_depth_ddl.parent(id) ON DELETE CASCADE,
            email TEXT UNIQUE,
            note TEXT DEFAULT 'n/a' NOT NULL
        )
        """, params: nil)
        _ = try await conn.execute("CREATE INDEX idx_depth_note ON si_depth_ddl.child (note)", params: nil)
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS si_depth_ddl CASCADE", params: nil) } }

        // 原生 postgres:16 无 pg_get_tabledef；DDL 必须仍可得。
        let ddl = try #require(await PostgreSQLIntrospector().loadDDL(
            for: DatabaseObject(kind: .table, name: "child", database: "testdb", schema: "si_depth_ddl"), in: conn))
        #expect(ddl.contains("CREATE TABLE"))
        #expect(ddl.contains("si_depth_ddl.child"))
        #expect(ddl.uppercased().contains("PRIMARY KEY"))
        #expect(ddl.contains("REFERENCES si_depth_ddl.parent"))
        #expect(ddl.uppercased().contains("ON DELETE CASCADE"))
        #expect(ddl.contains("idx_depth_note"))
        #expect(ddl.contains("'n/a'"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_PG_PORT"] != nil))
    func pgLoadDDLForViewMatviewAndFunctionAndSchemaScopedMatviews() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LODE_TEST_PG_PORT"].flatMap(Int.init))
        let conn = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        defer { Task { await conn.close() } }
        _ = try await conn.execute("DROP SCHEMA IF EXISTS si_depth_obj CASCADE", params: nil)
        _ = try await conn.execute("CREATE SCHEMA si_depth_obj", params: nil)
        _ = try await conn.execute("CREATE TABLE si_depth_obj.parent (id INTEGER PRIMARY KEY)", params: nil)
        _ = try await conn.execute("CREATE VIEW si_depth_obj.v AS SELECT id FROM si_depth_obj.parent", params: nil)
        _ = try await conn.execute("CREATE MATERIALIZED VIEW si_depth_obj.mv AS SELECT id FROM si_depth_obj.parent", params: nil)
        _ = try await conn.execute("CREATE FUNCTION si_depth_obj.fn() RETURNS INTEGER AS $$ SELECT 42 $$ LANGUAGE sql", params: nil)
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS si_depth_obj CASCADE", params: nil) } }

        let introspector = PostgreSQLIntrospector()
        let viewDDL = try await introspector.loadDDL(
            for: DatabaseObject(kind: .view, name: "v", database: "testdb", schema: "si_depth_obj"), in: conn)
        #expect(viewDDL?.contains("si_depth_obj.parent") == true)

        let mvDDL = try await introspector.loadDDL(
            for: DatabaseObject(kind: .materializedView, name: "mv", database: "testdb", schema: "si_depth_obj"), in: conn)
        #expect(mvDDL?.contains("si_depth_obj.parent") == true)

        let fnDDL = try await introspector.loadDDL(
            for: DatabaseObject(kind: .function, name: "fn", database: "testdb", schema: "si_depth_obj"), in: conn)
        #expect(fnDDL?.uppercased().contains("FUNCTION") == true)
        #expect(fnDDL?.contains("42") == true)

        // 物化视图列表必须尊重指定 schema，而非 current_schema()。
        let matviews = try await introspector.loadObjects(
            of: .materializedView, in: conn, database: "testdb", schema: "si_depth_obj")
        #expect(matviews.contains { $0.name == "mv" && $0.schema == "si_depth_obj" })
    }
}