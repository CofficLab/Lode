import Foundation

/// MCP（Model Context Protocol）stdio 会话核心。
///
/// 以 JSON-RPC 2.0 暴露四个只读数据库工具，与宿主 Agent 工具同一服务层：
/// 连接允许列表、只读 SQL 策略、脱敏审计全部复用。安全模型：
/// - 令牌认证在进程入口完成（``DatabaseMCPTokenStore``）；
/// - 敏感表采样 / 跨连接访问 / `--require-consent` 模式下逐次调用经
///   MCP elicitation 向用户征求同意；客户端不支持 elicitation 时拒绝执行；
/// - 返回给客户端的错误文本一律经 ``LogRedactor`` 脱敏。
///
/// 传输抽象为 `send` 闭包（stdio 写 stdout；测试捕获消息），入站消息经
/// ``receive(_:)`` 逐行喂入。actor 在等待同意/查询时让出，elicitation 响应
/// 可重入处理，不会死锁。
public actor DatabaseMCPSession {
    public static let supportedProtocolVersions = ["2025-06-18", "2024-11-05"]
    public static let serverName = "lode-database-mcp"
    public static let serverVersion = "1.0.0"
    static let elicitationTimeoutSeconds: UInt64 = 120

    private enum ConsentOutcome {
        case approved, declined, unsupported
    }

    private let service: DatabaseAgentToolService
    private let policy: DatabaseAgentAccessPolicy
    private let requireConsent: Bool
    private let send: @Sendable (Data) -> Void

    private var negotiatedVersion: String?
    private var clientSupportsElicitation = false
    private var nextRequestID = 1
    private var pendingElicitations: [Int: CheckedContinuation<Bool, Never>] = [:]

    public init(
        service: DatabaseAgentToolService = .shared,
        policy: DatabaseAgentAccessPolicy = .shared,
        requireConsent: Bool = false,
        send: @escaping @Sendable (Data) -> Void
    ) {
        self.service = service
        self.policy = policy
        self.requireConsent = requireConsent
        self.send = send
    }

    /// 处理一行入站 JSON-RPC 消息（请求/通知/对我们 elicitation 的响应）。
    public func receive(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            sendError(id: nil, code: -32700, message: "Parse error")
            return
        }
        if object["method"] == nil {
            handleResponse(object)
            return
        }
        await handleRequest(object)
    }

    // MARK: - Requests

    private func handleRequest(_ object: [String: Any]) async {
        let method = object["method"] as? String ?? ""
        let id = object["id"]
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            negotiatedVersion = Self.supportedProtocolVersions.contains(requested)
                ? requested
                : Self.supportedProtocolVersions[0]
            clientSupportsElicitation = (params["capabilities"] as? [String: Any])?["elicitation"] != nil
            respond(id, [
                "protocolVersion": negotiatedVersion ?? Self.supportedProtocolVersions[0],
                "capabilities": ["tools": [:]],
                "serverInfo": [
                    "name": Self.serverName,
                    "title": "Lode Database Tools",
                    "version": Self.serverVersion,
                ],
            ])
        case "notifications/initialized", "notifications/cancelled":
            return
        case "ping":
            guard isInitialized else { return sendError(id: id, code: -32002, message: "Server not initialized") }
            respond(id, [:])
        case "tools/list":
            guard isInitialized else { return sendError(id: id, code: -32002, message: "Server not initialized") }
            respond(id, ["tools": Self.toolDefinitions])
        case "tools/call":
            guard isInitialized else { return sendError(id: id, code: -32002, message: "Server not initialized") }
            await handleToolCall(id: id, params: params)
        default:
            guard id != nil else { return }
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private var isInitialized: Bool { negotiatedVersion != nil }

    private func handleToolCall(id: Any?, params: [String: Any]) async {
        guard let name = params["name"] as? String else {
            return sendError(id: id, code: -32602, message: "Missing tool name")
        }
        guard Self.toolNames.contains(name) else {
            return sendError(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        if needsConsent(tool: name, arguments: arguments) {
            switch await requestConsent(tool: name, arguments: arguments) {
            case .approved:
                break
            case .declined:
                return respond(id, Self.toolError("User declined the tool call."))
            case .unsupported:
                return respond(id, Self.toolError(
                    "This tool call requires user approval, but the MCP client does not support elicitation. Use a client with elicitation support, or adjust the connection's Agent Access setting."
                ))
            }
        }

        do {
            let text = try await execute(tool: name, arguments: arguments)
            respond(id, ["content": [["type": "text", "text": text]], "isError": false])
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            respond(id, Self.toolError(Self.redacted(message)))
        }
    }

    private func execute(tool: String, arguments: [String: Any]) async throws -> String {
        switch tool {
        case "database_list_connections":
            return try await service.listConnections()
        case "database_describe_schema":
            return try await service.describeSchema(
                connectionId: Self.connectionID(arguments),
                limit: Self.limit(arguments),
                schemaName: Self.optionalString(arguments, "schema")
            )
        case "database_query_readonly":
            return try await service.queryReadonly(
                connectionId: Self.connectionID(arguments),
                sql: try Self.requiredString(arguments, "sql"),
                limit: Self.limit(arguments)
            )
        case "database_sample_table":
            return try await service.sampleTable(
                connectionId: Self.connectionID(arguments),
                table: try Self.requiredString(arguments, "table"),
                limit: Self.limit(arguments)
            )
        default:
            throw DatabaseAgentToolError.missingArgument("name")
        }
    }

    // MARK: - Consent

    private func needsConsent(tool: String, arguments: [String: Any]) -> Bool {
        if requireConsent { return true }
        if tool == "database_sample_table",
           let table = arguments["table"] as? String,
           DatabaseAgentAccessPolicy.isSensitiveTableName(table) {
            return true
        }
        if let id = try? DatabaseAgentToolService.connectionId(from: arguments["connection_id"]),
           policy.isCrossConnection(id) {
            return true
        }
        return false
    }

    private func requestConsent(tool: String, arguments: [String: Any]) async -> ConsentOutcome {
        guard clientSupportsElicitation else { return .unsupported }
        let requestID = nextRequestID
        nextRequestID += 1

        var message = "Allow \(tool)"
        if let connectionId = arguments["connection_id"] as? String {
            message += " on connection \(connectionId)"
        }
        if let table = arguments["table"] as? String {
            message += " (table: \(table))"
        }
        message += "?"

        sendJSON([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "elicitation/create",
            "params": [
                "message": message,
                "requestedSchema": [
                    "type": "object",
                    "properties": [
                        "approved": ["type": "boolean", "description": "Allow this database tool call?"],
                    ],
                    "required": ["approved"],
                ],
            ],
        ])

        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingElicitations[requestID] = continuation
            // 客户端迟迟不响应时按拒绝处理，避免调用永久挂起。
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.elicitationTimeoutSeconds * 1_000_000_000)
                await self?.timeoutElicitation(requestID)
            }
        }
        return approved ? .approved : .declined
    }

    private func timeoutElicitation(_ requestID: Int) {
        if let continuation = pendingElicitations.removeValue(forKey: requestID) {
            continuation.resume(returning: false)
        }
    }

    /// 客户端对我们 elicitation 请求的响应。
    private func handleResponse(_ object: [String: Any]) {
        guard let id = object["id"] as? Int,
              let continuation = pendingElicitations.removeValue(forKey: id) else {
            return
        }
        let result = object["result"] as? [String: Any]
        let content = result?["content"] as? [String: Any]
        let approved = (result?["action"] as? String) == "accept"
            && (content?["approved"] as? Bool) == true
        continuation.resume(returning: approved)
    }

    // MARK: - Transport helpers

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(data)
    }

    private func respond(_ id: Any?, _ result: [String: Any]) {
        guard let id else { return }
        sendJSON(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: Any?, code: Int, message: String) {
        sendJSON([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": Self.redacted(message)],
        ])
    }

    static func redacted(_ message: String) -> String {
        LogRedactor.redact(message)
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: - Argument helpers

    private static func connectionID(_ arguments: [String: Any]) throws -> UUID {
        try DatabaseAgentToolService.connectionId(from: arguments["connection_id"])
    }

    private static func limit(_ arguments: [String: Any]) throws -> Int {
        try DatabaseAgentToolService.normalizedLimit(arguments["limit"])
    }

    private static func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw DatabaseAgentToolError.missingArgument(key)
        }
        return value
    }

    private static func optionalString(_ arguments: [String: Any], _ key: String) -> String? {
        guard let value = arguments[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Tool contract

    public static let toolNames = [
        "database_list_connections",
        "database_describe_schema",
        "database_query_readonly",
        "database_sample_table",
    ]

    private static var readOnlyAnnotations: [String: Any] {
        [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false,
        ]
    }

    private static func schema(properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static let connectionIdProperty: [String: String] = [
        "type": "string",
        "description": "Connection UUID returned by database_list_connections",
    ]

    private static let limitProperty: [String: String] = [
        "type": "integer",
        "description": "Maximum entries to return; default 100, maximum 1000.",
    ]

    static var toolDefinitions: [[String: Any]] {
        [
        [
            "name": "database_list_connections",
            "description": "List database connections available to Agent database tools. Passwords and secrets are never returned.",
            "inputSchema": schema(properties: [:], required: []),
            "annotations": readOnlyAnnotations,
        ],
        [
            "name": "database_describe_schema",
            "description": "Describe tables, columns, or key samples for an Agent-accessible database connection.",
            "inputSchema": schema(
                properties: [
                    "connection_id": connectionIdProperty,
                    "limit": limitProperty,
                    "schema": [
                        "type": "string",
                        "description": "Optional schema to restrict the description to (PostgreSQL). Omit it to describe every non-system schema.",
                    ],
                ],
                required: ["connection_id"]
            ),
            "annotations": readOnlyAnnotations,
        ],
        [
            "name": "database_query_readonly",
            "description": "Run a read-only SQL query. Mutating and administrative statements are rejected.",
            "inputSchema": schema(
                properties: [
                    "connection_id": connectionIdProperty,
                    "sql": ["type": "string", "description": "Read-only SQL."],
                    "limit": limitProperty,
                ],
                required: ["connection_id", "sql"]
            ),
            "annotations": readOnlyAnnotations,
        ],
        [
            "name": "database_sample_table",
            "description": "Return a small sample from a table using safe identifier quoting.",
            "inputSchema": schema(
                properties: [
                    "connection_id": connectionIdProperty,
                    "table": ["type": "string", "description": "Table name, optionally schema-qualified."],
                    "limit": limitProperty,
                ],
                required: ["connection_id", "table"]
            ),
            "annotations": readOnlyAnnotations,
        ],
        ]
    }
}