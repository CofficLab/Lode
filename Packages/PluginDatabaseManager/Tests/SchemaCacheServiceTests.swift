import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// 缓存污染回归：loadSchemas 曾把 schema 列表写进数据库列表缓存，
/// 导致 PG 加载 schema 后数据库列表被覆盖。
@MainActor
struct SchemaCacheServiceTests {
    struct MockIntrospector: DatabaseIntrospector {
        var databases: [String] = ["app_db", "analytics"]
        var schemas: [String] = ["public", "billing"]

        func loadDatabases(in connection: any DatabaseConnection) async throws -> [String] { databases }
        func loadSchemas(in connection: any DatabaseConnection, database: String?) async throws -> [String] { schemas }
        func loadObjects(of kind: DatabaseObjectKind, in connection: any DatabaseConnection, database: String?, schema: String?) async throws -> [DatabaseObject] { [] }
        func describeTable(_ object: DatabaseObject, in connection: any DatabaseConnection) async throws -> TableSchema {
            TableSchema(table: object, columns: [])
        }
        func loadDDL(for object: DatabaseObject, in connection: any DatabaseConnection) async throws -> String? { nil }
    }

    final class DummyConnection: DatabaseConnection, @unchecked Sendable {
        func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int { 0 }
        func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
            QueryResult(columns: [], rows: [], rowsAffected: 0)
        }
        func beginTransaction() async throws -> any DatabaseTransaction { fatalError("unused") }
        func close() async {}
        func isAlive() async -> Bool { true }
        func cancel() async {}
    }

    private func makeService(_ introspector: MockIntrospector = MockIntrospector()) -> SchemaCacheService {
        SchemaCacheService { _ in introspector }
    }

    private let config = DatabaseConfig(name: "pg", type: .postgresql, database: "app_db")

    @Test("loadSchemas 不污染数据库列表缓存")
    func schemasDoNotPoisonDatabaseCache() async throws {
        let service = makeService()
        let connection = DummyConnection()

        let databases = try await service.loadDatabases(for: config, connection: connection)
        #expect(databases == ["app_db", "analytics"])

        let schemas = try await service.loadSchemas(for: config, database: "app_db", connection: connection)
        #expect(schemas == ["public", "billing"])

        // 关键断言：数据库列表缓存未被 schema 列表覆盖。
        let databasesAgain = try await service.loadDatabases(for: config, connection: connection)
        #expect(databasesAgain == ["app_db", "analytics"])
        #expect(service.databasesByConfig[config.id] == ["app_db", "analytics"])
    }

    @Test("schema 列表按 (连接, 库) 独立缓存")
    func schemasCachedPerDatabase() async throws {
        var introspector = MockIntrospector()
        let service = makeService(introspector)
        let connection = DummyConnection()

        _ = try await service.loadSchemas(for: config, database: "app_db", connection: connection)
        introspector.schemas = ["other"]
        // 已缓存的库不受 introspector 变化影响（命中缓存）。
        let cached = try await service.loadSchemas(for: config, database: "app_db", connection: connection)
        #expect(cached == ["public", "billing"])
    }

    @Test("invalidate 清空该连接的数据库与 schema 缓存")
    func invalidateClearsBothCaches() async throws {
        let service = makeService()
        let connection = DummyConnection()
        _ = try await service.loadDatabases(for: config, connection: connection)
        _ = try await service.loadSchemas(for: config, database: "app_db", connection: connection)

        service.invalidate(configId: config.id)
        #expect(service.databasesByConfig[config.id] == nil)
        #expect(service.schemasByKey.isEmpty)
    }
}