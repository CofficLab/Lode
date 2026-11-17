import Testing
import Foundation
import KitAgentTool
@testable import DatabaseManagerPlugin

/// 连接级 Agent 允许列表、跨连接/敏感表风险分级与审计日志的行为测试。
@Suite struct DatabaseAgentAccessPolicyTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "DatabaseAgentAccessPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func connectionsAreAllowedByDefault() {
        let policy = DatabaseAgentAccessPolicy(defaults: makeDefaults())
        #expect(policy.isAllowed(UUID()))
    }

    @Test func blockingPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let id = UUID()
        let policy = DatabaseAgentAccessPolicy(defaults: defaults)
        policy.setAllowed(false, for: id)
        #expect(!policy.isAllowed(id))

        let reloaded = DatabaseAgentAccessPolicy(defaults: defaults)
        #expect(!reloaded.isAllowed(id))
        reloaded.setAllowed(true, for: id)
        #expect(DatabaseAgentAccessPolicy(defaults: defaults).isAllowed(id))
    }

    @Test func crossConnectionRequiresActiveConnection() {
        let policy = DatabaseAgentAccessPolicy(defaults: makeDefaults())
        let a = UUID()
        let b = UUID()
        #expect(!policy.isCrossConnection(a))
        policy.activeConnectionId = a
        #expect(!policy.isCrossConnection(a))
        #expect(policy.isCrossConnection(b))
        policy.activeConnectionId = nil
        #expect(!policy.isCrossConnection(b))
    }

    @Test(arguments: [
        "user_passwords", " Secrets ", "api_keys", "refresh_token", "payments",
        "credit_card", "privatekey", "ssn_records", "vault.CREDENTIALS",
    ])
    func sensitiveTableNamesAreFlagged(name: String) {
        #expect(DatabaseAgentAccessPolicy.isSensitiveTableName(name))
    }

    @Test(arguments: ["users", "order_items", "sqlite_master", "inventory"])
    func ordinaryTableNamesAreNotFlagged(name: String) {
        #expect(!DatabaseAgentAccessPolicy.isSensitiveTableName(name))
    }
}

@Suite struct DatabaseAgentAuditLogTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "DatabaseAgentAuditLogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func entriesAreNewestFirstAndPersist() {
        let defaults = makeDefaults()
        let log = DatabaseAgentAuditLog(defaults: defaults)
        log.record(tool: "database_query_readonly", connectionId: "c1", connectionName: "Dev", detail: "SELECT 1", outcome: "ok")
        log.record(tool: "database_sample_table", connectionId: "c1", connectionName: "Dev", detail: "table=users", outcome: "ok")

        let reloaded = DatabaseAgentAuditLog(defaults: defaults)
        let recent = reloaded.recent()
        #expect(recent.count == 2)
        #expect(recent[0].tool == "database_sample_table")
        #expect(recent[1].detail == "SELECT 1")
        #expect(recent[1].connectionName == "Dev")
    }

    @Test func detailIsTruncatedAndRedacted() {
        let log = DatabaseAgentAuditLog(defaults: makeDefaults())
        let longSQL = "SELECT * FROM t WHERE password=hunter2 AND note='\(String(repeating: "x", count: 400))'"
        log.record(tool: "database_query_readonly", connectionId: nil, connectionName: nil, detail: longSQL, outcome: "ok")
        let entry = log.recent()[0]
        #expect(entry.detail.count <= DatabaseAgentAuditLog.maxDetailLength + 1)
        #expect(entry.detail.contains(LogRedactor.marker))
        #expect(!entry.detail.contains("hunter2"))
    }

    @Test func ringBufferCapsAtMaxEntries() {
        let log = DatabaseAgentAuditLog(defaults: makeDefaults())
        for i in 0..<(DatabaseAgentAuditLog.maxEntries + 25) {
            log.record(tool: "t", connectionId: nil, connectionName: nil, detail: "\(i)", outcome: "ok")
        }
        let recent = log.recent()
        #expect(recent.count == DatabaseAgentAuditLog.maxEntries)
        #expect(recent[0].detail == "\(DatabaseAgentAuditLog.maxEntries + 24)")
    }

    @Test func clearRemovesEverything() {
        let defaults = makeDefaults()
        let log = DatabaseAgentAuditLog(defaults: defaults)
        log.record(tool: "t", connectionId: nil, connectionName: nil, detail: "", outcome: "ok")
        log.clear()
        #expect(log.recent().isEmpty)
        #expect(DatabaseAgentAuditLog(defaults: defaults).recent().isEmpty)
    }
}

/// 工具风险分级：跨连接与敏感表采样升级为 .high（宿主据此弹出审批）。
@Suite(.serialized) struct DatabaseAgentToolRiskTests {

    @Test func sampleOfSensitiveTableRequiresApproval() {
        let tool = DatabaseSampleTableV2Tool()
        let arguments: [String: ToolArgument] = [
            "connection_id": ToolArgument(UUID().uuidString),
            "table": ToolArgument("user_secrets"),
        ]
        #expect(tool.permissionRiskLevel(arguments: arguments) == .high)
    }

    @Test func sampleOfOrdinaryTableStaysLowRisk() {
        let tool = DatabaseSampleTableV2Tool()
        let arguments: [String: ToolArgument] = [
            "connection_id": ToolArgument(UUID().uuidString),
            "table": ToolArgument("users"),
        ]
        #expect(tool.permissionRiskLevel(arguments: arguments) == .low)
    }

    @Test func crossConnectionQueryRequiresApproval() {
        let active = UUID()
        let other = UUID()
        let policy = DatabaseAgentAccessPolicy.shared
        let previous = policy.activeConnectionId
        policy.activeConnectionId = active
        defer { policy.activeConnectionId = previous }

        let query = DatabaseReadonlyQueryV2Tool()
        let describe = DatabaseDescribeSchemaV2Tool()
        let sameArgs: [String: ToolArgument] = ["connection_id": ToolArgument(active.uuidString), "sql": ToolArgument("SELECT 1")]
        let otherArgs: [String: ToolArgument] = ["connection_id": ToolArgument(other.uuidString), "sql": ToolArgument("SELECT 1")]
        #expect(query.permissionRiskLevel(arguments: sameArgs) == .low)
        #expect(query.permissionRiskLevel(arguments: otherArgs) == .high)
        #expect(describe.permissionRiskLevel(arguments: otherArgs) == .high)
    }

    @Test func listConnectionsStaysLowRisk() {
        #expect(DatabaseListConnectionsV2Tool().permissionRiskLevel(arguments: [:]) == .low)
    }
}

/// 允许列表在服务层的强制执行：被禁连接对 Agent 工具不可见也不可访问。
@Suite(.serialized) struct DatabaseAgentAllowlistEnforcementTests {

    @Test func blockedConnectionIsHiddenAndRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseAgentAllowlist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "allowlist.sqlite")

        let id = UUID()
        let config = DatabaseConfig(id: id, name: "AllowlistProbe", type: .sqlite, database: url.path)
        let setup = DatabaseManagerCore()
        await setup.register(driver: SQLiteDriver())
        let connection = try await setup.connect(config: config)
        _ = try await connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY)", params: nil)
        await connection.close()

        await DatabaseAgentConnectionRegistry.shared.upsert(config)
        let policy = DatabaseAgentAccessPolicy.shared
        policy.setAllowed(false, for: id)
        defer {
            policy.setAllowed(true, for: id)
            Task {
                await DatabaseAgentConnectionRegistry.shared.remove(id: id)
                await DatabaseManagerCore.shared.disconnect(configId: id)
            }
        }

        let listing = try await DatabaseAgentToolService.shared.listConnections()
        #expect(!listing.contains(id.uuidString))

        await #expect(throws: DatabaseAgentToolError.self) {
            _ = try await DatabaseAgentToolService.shared.queryReadonly(connectionId: id, sql: "SELECT 1", limit: 10)
        }
        await #expect(throws: DatabaseAgentToolError.self) {
            _ = try await DatabaseAgentToolService.shared.describeSchema(connectionId: id, limit: 10)
        }
        await #expect(throws: DatabaseAgentToolError.self) {
            _ = try await DatabaseAgentToolService.shared.sampleTable(connectionId: id, table: "users", limit: 10)
        }

        // 拒绝必须留下审计痕迹（outcome=denied）。
        let denied = DatabaseAgentAuditLog.shared.recent().filter {
            $0.connectionId == id.uuidString && $0.outcome == "denied"
        }
        #expect(denied.count >= 3)

        // 解除禁用后恢复访问。
        policy.setAllowed(true, for: id)
        let result = try await DatabaseAgentToolService.shared.queryReadonly(connectionId: id, sql: "SELECT name FROM sqlite_master WHERE type = 'table'", limit: 10)
        #expect(result.contains("users"))
        let restored = try await DatabaseAgentToolService.shared.listConnections()
        #expect(restored.contains(id.uuidString))
    }
}