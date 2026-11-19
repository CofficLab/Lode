import KitAgentTool
import Foundation

/// KernelCore adapters for the stable database Agent tool contract.
public struct DatabaseListConnectionsV2Tool: SuperAgentTool {
    public static let toolName = "database_list_connections"
    public let name = Self.toolName
    public init() {}
    public func description(for language: LanguagePreference) -> String { "List database connections available to Agent database tools. Passwords and secrets are never returned." }
    public func inputSchema(for language: LanguagePreference) -> [String: Any] { ["type": "object", "properties": [:]] }
    public func displayDescription(for arguments: [String: ToolArgument]) -> String { "List database connections" }
    public func permissionRiskLevel(arguments: [String: ToolArgument]) -> CommandRiskLevel { .low }
    public func execute(arguments: [String: ToolArgument]) async throws -> String { try await DatabaseAgentToolService.shared.listConnections() }
}

public struct DatabaseDescribeSchemaV2Tool: SuperAgentTool {
    public static let toolName = "database_describe_schema"
    public let name = Self.toolName
    public init() {}
    public func description(for language: LanguagePreference) -> String { "Describe tables, columns, or key samples for an Agent-accessible database connection." }
    public func inputSchema(for language: LanguagePreference) -> [String: Any] { DatabaseV2ToolSupport.schema(properties: ["connection_id": DatabaseV2ToolSupport.string("Connection UUID returned by database_list_connections"), "limit": DatabaseV2ToolSupport.integer("Maximum entries to return; default 100, maximum 1000."), "schema": DatabaseV2ToolSupport.string("Optional schema to restrict the description to (PostgreSQL). Omit it to describe every non-system schema.")], required: ["connection_id"]) }
    public func displayDescription(for arguments: [String: ToolArgument]) -> String { "Describe database schema" }
    public func permissionRiskLevel(arguments: [String: ToolArgument]) -> CommandRiskLevel { DatabaseV2ToolSupport.crossConnectionRisk(arguments) }
    public func execute(arguments: [String: ToolArgument]) async throws -> String { try await DatabaseAgentToolService.shared.describeSchema(connectionId: DatabaseV2ToolSupport.connectionID(arguments), limit: DatabaseV2ToolSupport.limit(arguments), schemaName: DatabaseV2ToolSupport.optionalString(arguments, "schema")) }
}

public struct DatabaseReadonlyQueryV2Tool: SuperAgentTool {
    public static let toolName = "database_query_readonly"
    public let name = Self.toolName
    public init() {}
    public func description(for language: LanguagePreference) -> String { "Run a read-only SQL query immediately and return rows. Mutating and administrative statements are rejected. To draft SQL for the user's editor without executing it, use database_propose_sql instead." }
    public func inputSchema(for language: LanguagePreference) -> [String: Any] { DatabaseV2ToolSupport.schema(properties: ["connection_id": DatabaseV2ToolSupport.string("Connection UUID returned by database_list_connections"), "sql": DatabaseV2ToolSupport.string("Read-only SQL."), "limit": DatabaseV2ToolSupport.integer("Maximum result rows; default 100, maximum 1000.")], required: ["connection_id", "sql"]) }
    public func displayDescription(for arguments: [String: ToolArgument]) -> String { "Run read-only database query" }
    public func permissionRiskLevel(arguments: [String: ToolArgument]) -> CommandRiskLevel { DatabaseV2ToolSupport.crossConnectionRisk(arguments) }
    public func execute(arguments: [String: ToolArgument]) async throws -> String { try await DatabaseAgentToolService.shared.queryReadonly(connectionId: DatabaseV2ToolSupport.connectionID(arguments), sql: try DatabaseV2ToolSupport.requiredString(arguments, "sql"), limit: DatabaseV2ToolSupport.limit(arguments)) }
}

public struct DatabaseSampleTableV2Tool: SuperAgentTool {
    public static let toolName = "database_sample_table"
    public let name = Self.toolName
    public init() {}
    public func description(for language: LanguagePreference) -> String { "Return a small sample from a table using safe identifier quoting." }
    public func inputSchema(for language: LanguagePreference) -> [String: Any] { DatabaseV2ToolSupport.schema(properties: ["connection_id": DatabaseV2ToolSupport.string("Connection UUID returned by database_list_connections"), "table": DatabaseV2ToolSupport.string("Table name, optionally schema-qualified."), "limit": DatabaseV2ToolSupport.integer("Maximum result rows; default 100, maximum 1000.")], required: ["connection_id", "table"]) }
    public func displayDescription(for arguments: [String: ToolArgument]) -> String { "Sample database table" }
    public func permissionRiskLevel(arguments: [String: ToolArgument]) -> CommandRiskLevel {
        if let table = arguments["table"]?.value as? String,
           DatabaseAgentAccessPolicy.isSensitiveTableName(table) {
            return .high
        }
        return DatabaseV2ToolSupport.crossConnectionRisk(arguments)
    }
    public func execute(arguments: [String: ToolArgument]) async throws -> String { try await DatabaseAgentToolService.shared.sampleTable(connectionId: DatabaseV2ToolSupport.connectionID(arguments), table: try DatabaseV2ToolSupport.requiredString(arguments, "table"), limit: DatabaseV2ToolSupport.limit(arguments)) }
}

public struct DatabaseProposeSQLV2Tool: SuperAgentTool {
    public static let toolName = "database_propose_sql"
    public let name = Self.toolName
    public init() {}
    public func description(for language: LanguagePreference) -> String { "Place generated SQL into the user's current SQL editor for review without executing it. Use the connection_id, query_tab_id, and single-use proposal_token injected for the active database workspace. The user must explicitly click Run." }
    public func inputSchema(for language: LanguagePreference) -> [String: Any] {
        DatabaseV2ToolSupport.schema(
            properties: [
                "connection_id": DatabaseV2ToolSupport.string("Active database connection UUID from the database workspace context."),
                "query_tab_id": DatabaseV2ToolSupport.string("Active query tab UUID from the database workspace context."),
                "proposal_token": DatabaseV2ToolSupport.string("Single-use proposal_token from the database workspace context."),
                "sql": DatabaseV2ToolSupport.string("Complete SQL to place in the editor. It will not be executed."),
            ],
            required: ["connection_id", "query_tab_id", "proposal_token", "sql"]
        )
    }
    public func displayDescription(for arguments: [String: ToolArgument]) -> String { "Insert SQL into editor without running it" }
    public func permissionRiskLevel(arguments: [String: ToolArgument]) -> CommandRiskLevel { DatabaseV2ToolSupport.crossConnectionRisk(arguments) }
    public func execute(arguments: [String: ToolArgument]) async throws -> String {
        let connectionID = try DatabaseV2ToolSupport.connectionID(arguments)
        let queryTabID = try DatabaseV2ToolSupport.uuid(arguments, "query_tab_id")
        let token = try DatabaseV2ToolSupport.uuid(arguments, "proposal_token")
        let sql = try DatabaseV2ToolSupport.requiredString(arguments, "sql")
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatabaseAgentToolError.missingArgument("sql")
        }
        do {
            let receipt = try await MainActor.run {
                try DatabaseSQLProposalRuntime.shared.apply(
                    token: token,
                    connectionID: connectionID,
                    queryTabID: queryTabID,
                    sql: sql
                )
            }
            DatabaseAgentAuditLog.shared.record(
                tool: Self.toolName,
                connectionId: connectionID.uuidString,
                connectionName: nil,
                detail: "Editor only; not executed. SQL: \(sql)",
                outcome: "editor_only"
            )
            let data = try JSONEncoder().encode(receipt)
            return String(decoding: data, as: UTF8.self)
        } catch {
            DatabaseAgentAuditLog.shared.record(
                tool: Self.toolName,
                connectionId: connectionID.uuidString,
                connectionName: nil,
                detail: "Editor proposal rejected; SQL was not executed.",
                outcome: "rejected"
            )
            throw error
        }
    }
}

private enum DatabaseV2ToolSupport {
    /// 跨连接访问需用户审批（.high 触发宿主授权 UI）；无法解析连接 id 时
    /// 保持 .low，执行阶段会给出明确错误。
    static func crossConnectionRisk(_ arguments: [String: ToolArgument]) -> CommandRiskLevel {
        guard let id = try? connectionID(arguments) else { return .low }
        return DatabaseAgentAccessPolicy.shared.isCrossConnection(id) ? .high : .low
    }
    static func schema(properties: [String: Any], required: [String]) -> [String: Any] { ["type": "object", "properties": properties, "required": required] }
    static func string(_ description: String) -> [String: String] { ["type": "string", "description": description] }
    static func integer(_ description: String) -> [String: String] { ["type": "integer", "description": description] }
    static func connectionID(_ arguments: [String: ToolArgument]) throws -> UUID { try DatabaseAgentToolService.connectionId(from: arguments["connection_id"]?.value) }
    static func limit(_ arguments: [String: ToolArgument]) throws -> Int { try DatabaseAgentToolService.normalizedLimit(arguments["limit"]?.value) }
    static func requiredString(_ arguments: [String: ToolArgument], _ key: String) throws -> String {
        guard let value = arguments[key]?.value as? String, !value.isEmpty else { throw DatabaseAgentToolError.missingArgument(key) }
        return value
    }
    static func uuid(_ arguments: [String: ToolArgument], _ key: String) throws -> UUID {
        let value = try requiredString(arguments, key)
        guard let id = UUID(uuidString: value) else {
            throw DatabaseAgentToolError.invalidUUID(argument: key, value: value)
        }
        return id
    }
    /// 可选字符串参数：缺省或空白视为未提供。
    static func optionalString(_ arguments: [String: ToolArgument], _ key: String) -> String? {
        guard let value = arguments[key]?.value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
