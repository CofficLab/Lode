import Foundation

/// 连接级补全元数据缓存（LRU 上限）。
///
/// 复用 ``SchemaCacheService`` 的对象/结构缓存，把"表 + 列 + schema"组装成
/// ``SQLCompletionMetadata`` 供补全引擎离线消费。按 (连接, 库, schema) 缓存，
/// 容量受限淘汰最久未用；结构变更（DDL）后由调用方 ``invalidate(configId:)`` 刷新。
@MainActor
public final class SQLCompletionMetadataCache {
    public struct Key: Hashable, Sendable {
        public let configId: UUID
        public let database: String?
        public let schema: String?
    }

    private let schemaCache: SchemaCacheService
    private let capacity: Int
    /// 单连接最多加载多少张表的列；超出仍列出表名但不展开列，避免大库首屏卡顿。
    private let columnTableLimit: Int
    private var entries: [Key: SQLCompletionMetadata] = [:]
    private var order: [Key] = []

    public init(schemaCache: SchemaCacheService, capacity: Int = 8, columnTableLimit: Int = 200) {
        self.schemaCache = schemaCache
        self.capacity = max(1, capacity)
        self.columnTableLimit = max(1, columnTableLimit)
    }

    public func metadata(
        for config: DatabaseConfig,
        connection: any DatabaseConnection,
        refresh: Bool = false
    ) async throws -> SQLCompletionMetadata {
        let key = Key(configId: config.id, database: config.database, schema: nil)
        if !refresh, let cached = entries[key] {
            touch(key)
            return cached
        }

        var tables: [SQLCompletionTable] = []
        var objects: [DatabaseObject] = []
        objects += try await schemaCache.objects(for: config, kind: .table, database: config.database, schema: nil, connection: connection, refresh: refresh)
        objects += try await schemaCache.objects(for: config, kind: .view, database: config.database, schema: nil, connection: connection, refresh: refresh)

        for (index, object) in objects.enumerated() {
            if index < columnTableLimit {
                let schema = try await schemaCache.tableSchema(for: object, config: config, connection: connection, refresh: refresh)
                let columns = schema.columns.map {
                    SQLCompletionColumn(name: $0.name, dataType: $0.dataType, isPrimaryKey: $0.isPrimaryKey)
                }
                tables.append(SQLCompletionTable(name: object.name, schema: object.schema, columns: columns))
            } else {
                tables.append(SQLCompletionTable(name: object.name, schema: object.schema, columns: []))
            }
        }

        var schemas: [String] = []
        if config.type == .postgresql {
            schemas = (try? await schemaCache.loadSchemas(for: config, database: config.database, connection: connection, refresh: refresh)) ?? []
        }

        let metadata = SQLCompletionMetadata(tables: tables, schemas: schemas)
        entries[key] = metadata
        touch(key)
        evictIfNeeded()
        return metadata
    }

    public func invalidate(configId: UUID) {
        let keys = entries.keys.filter { $0.configId == configId }
        for key in keys {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
        // 同时失效底层结构缓存，确保重新加载能读到 DDL 后的新对象。
        schemaCache.invalidate(configId: configId)
    }

    public func invalidateAll() {
        entries.removeAll()
        order.removeAll()
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}