import Foundation
import Combine

/// 数据库结构缓存：按 (连接, 对象类型, 库, schema) 缓存 ``DatabaseObject`` 列表。
///
/// 把"查表列表"这类高频元数据查询从 ViewModel 里抽出来，统一走
/// ``DatabaseIntrospector``，避免侧边栏每次展开都打一次数据库。
/// 侧边栏对象树（Phase 2）与结构 Tab（Phase 5）都从这里读数据。
@MainActor
public final class SchemaCacheService: ObservableObject {
    public struct CacheKey: Hashable, Sendable {
        public let configId: UUID
        public let kind: DatabaseObjectKind
        public let database: String?
        public let schema: String?

        public init(configId: UUID, kind: DatabaseObjectKind, database: String?, schema: String?) {
            self.configId = configId
            self.kind = kind
            self.database = database
            self.schema = schema
        }
    }

    public struct TableSchemaKey: Hashable, Sendable {
        public let configId: UUID
        public let objectId: String
    }

    /// schema 列表按 (连接, 库) 缓存：同一连接的不同库各有自己的 schema 集合。
    public struct SchemaListKey: Hashable, Sendable {
        public let configId: UUID
        public let database: String?

        public init(configId: UUID, database: String?) {
            self.configId = configId
            self.database = database
        }
    }

    @Published public private(set) var objectsByKey: [CacheKey: [DatabaseObject]] = [:]
    @Published public private(set) var databasesByConfig: [UUID: [String]] = [:]
    @Published public private(set) var schemasByKey: [SchemaListKey: [String]] = [:]
    @Published public private(set) var schemaByObject: [TableSchemaKey: TableSchema] = [:]
    @Published public private(set) var loadingKeys: Set<CacheKey> = []

    /// introspector 解析入口；测试可注入 mock，生产走 `DatabaseType.introspector`。
    private let introspectorResolver: @MainActor (DatabaseConfig) -> any DatabaseIntrospector

    public init(introspectorResolver: @escaping @MainActor (DatabaseConfig) -> any DatabaseIntrospector = { $0.type.introspector }) {
        self.introspectorResolver = introspectorResolver
    }

    /// 读取某分类下的对象；`refresh == true` 时强制重新加载。
    public func objects(
        for config: DatabaseConfig,
        kind: DatabaseObjectKind,
        database: String?,
        schema: String?,
        connection: any DatabaseConnection,
        refresh: Bool = false
    ) async throws -> [DatabaseObject] {
        let key = CacheKey(configId: config.id, kind: kind, database: database, schema: schema)
        if !refresh, let cached = objectsByKey[key] {
            return cached
        }
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }
        let introspector = introspectorResolver(config)
        let result = try await introspector.loadObjects(
            of: kind,
            in: connection,
            database: database,
            schema: schema
        )
        objectsByKey[key] = result
        return result
    }

    /// 加载服务器上的数据库列表（PG/MySQL/Redis），仅 `supportsMultipleDatabases` 时有意义。
    public func loadDatabases(for config: DatabaseConfig, connection: any DatabaseConnection, refresh: Bool = false) async throws -> [String] {
        if !refresh, let cached = databasesByConfig[config.id] {
            return cached
        }
        let introspector = introspectorResolver(config)
        let result = try await introspector.loadDatabases(in: connection)
        databasesByConfig[config.id] = result
        return result
    }

    /// 加载某库下的 schema 列表（PG）。
    public func loadSchemas(for config: DatabaseConfig, database: String?, connection: any DatabaseConnection, refresh: Bool = false) async throws -> [String] {
        let key = SchemaListKey(configId: config.id, database: database)
        if !refresh, let cached = schemasByKey[key] {
            return cached
        }
        let introspector = introspectorResolver(config)
        let result = try await introspector.loadSchemas(in: connection, database: database)
        schemasByKey[key] = result
        return result
    }

    /// 读取表结构；按对象 id 缓存。
    public func tableSchema(
        for object: DatabaseObject,
        config: DatabaseConfig,
        connection: any DatabaseConnection,
        refresh: Bool = false
    ) async throws -> TableSchema {
        let key = TableSchemaKey(configId: config.id, objectId: object.id)
        if !refresh, let cached = schemaByObject[key] {
            return cached
        }
        let introspector = introspectorResolver(config)
        let schema = try await introspector.describeTable(object, in: connection)
        schemaByObject[key] = schema
        return schema
    }

    /// 清空某连接的全部缓存（断开或重连时调用）。
    public func invalidate(configId: UUID) {
        objectsByKey = objectsByKey.filter { $0.key.configId != configId }
        databasesByConfig.removeValue(forKey: configId)
        schemasByKey = schemasByKey.filter { $0.key.configId != configId }
        schemaByObject = schemaByObject.filter { $0.key.configId != configId }
    }

    /// 清空全部缓存。
    public func invalidateAll() {
        objectsByKey.removeAll()
        databasesByConfig.removeAll()
        schemasByKey.removeAll()
        schemaByObject.removeAll()
    }
}
