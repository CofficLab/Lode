import Foundation
import KitAgentTool
import Testing
@testable import DatabaseManagerPlugin

/// V2 数据库工具契约：工具命名、描述文案、schema 形状、风险分级与参数校验。
/// execute 只测参数校验失败路径（在触达服务/网络前抛出），全部离线。
@Suite(.timeLimit(.minutes(1)))
struct DatabaseAgentV2ToolContractTests {
    private let list = DatabaseListConnectionsV2Tool()
    private let describe = DatabaseDescribeSchemaV2Tool()
    private let query = DatabaseReadonlyQueryV2Tool()
    private let sample = DatabaseSampleTableV2Tool()
    private let propose = DatabaseProposeSQLV2Tool()

    private func args(_ pairs: (String, Any)...) -> [String: ToolArgument] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, ToolArgument($0.1)) })
    }

    @Test("toolName 与实例 name 对齐")
    func toolNamesAligned() {
        #expect(DatabaseListConnectionsV2Tool.toolName == "database_list_connections")
        #expect(list.name == DatabaseListConnectionsV2Tool.toolName)
        #expect(DatabaseDescribeSchemaV2Tool.toolName == "database_describe_schema")
        #expect(describe.name == DatabaseDescribeSchemaV2Tool.toolName)
        #expect(DatabaseReadonlyQueryV2Tool.toolName == "database_query_readonly")
        #expect(query.name == DatabaseReadonlyQueryV2Tool.toolName)
        #expect(DatabaseSampleTableV2Tool.toolName == "database_sample_table")
        #expect(sample.name == DatabaseSampleTableV2Tool.toolName)
        #expect(DatabaseProposeSQLV2Tool.toolName == "database_propose_sql")
        #expect(propose.name == DatabaseProposeSQLV2Tool.toolName)
    }

    @Test("描述与展示文案覆盖语言偏好且非空")
    func descriptionsNonEmpty() {
        for language in [LanguagePreference.chinese, .english] {
            for tool in [list, describe, query, sample, propose] as [any SuperAgentTool] {
                #expect(!tool.description(for: language).isEmpty)
                #expect(!tool.displayDescription(for: [:]).isEmpty)
            }
        }
    }

    @Test("inputSchema 为 object 且 required 正确")
    func inputSchemaShape() {
        func required(_ schema: [String: Any]) -> [String] {
            schema["required"] as? [String] ?? []
        }
        #expect(list.inputSchema(for: .english)["type"] as? String == "object")
        #expect(required(describe.inputSchema(for: .english)) == ["connection_id"])
        #expect(required(query.inputSchema(for: .english)) == ["connection_id", "sql"])
        #expect(required(sample.inputSchema(for: .english)) == ["connection_id", "table"])
        #expect(required(propose.inputSchema(for: .english)) == ["connection_id", "query_tab_id", "proposal_token", "sql"])
    }

    @Test("list 工具固定低风险")
    func listToolLowRisk() {
        #expect(list.permissionRiskLevel(arguments: [:]) == .low)
    }

    @Test("样例敏感表名（大小写不敏感）升级为高风险")
    func sensitiveSampleTableHighRisk() {
        for table in ["user_passwords", "USER_TOKENS", "credit_cards"] {
            let arguments = args(("connection_id", UUID().uuidString), ("table", table))
            #expect(sample.permissionRiskLevel(arguments: arguments) == .high)
        }
    }

    @Test("普通表名样例请求保持低风险")
    func normalSampleTableLowRisk() {
        let arguments = args(("connection_id", UUID().uuidString), ("table", "customers"))
        #expect(sample.permissionRiskLevel(arguments: arguments) == .low)
    }

    @Test("execute 校验 connection_id")
    func executeValidatesConnectionId() async {
        await #expect(throws: DatabaseAgentToolError.missingArgument("connection_id")) {
            try await describe.execute(arguments: [:])
        }
        await #expect(throws: DatabaseAgentToolError.invalidConnectionId("nope")) {
            try await describe.execute(arguments: args(("connection_id", "nope")))
        }
        await #expect(throws: DatabaseAgentToolError.missingArgument("connection_id")) {
            try await query.execute(arguments: args(("connection_id", "")))
        }
    }

    @Test("execute 校验必填 SQL / 表名")
    func executeValidatesRequiredArguments() async {
        let id = UUID().uuidString
        await #expect(throws: DatabaseAgentToolError.missingArgument("sql")) {
            try await query.execute(arguments: args(("connection_id", id)))
        }
        // 空白 SQL 通过工具层必填校验（必填只查非空），随后在连接解析处被拒。
        await #expect(throws: DatabaseAgentToolError.connectionNotFound(id)) {
            try await query.execute(arguments: args(("connection_id", id), ("sql", "   ")))
        }
        await #expect(throws: DatabaseAgentToolError.missingArgument("table")) {
            try await sample.execute(arguments: args(("connection_id", id)))
        }
    }

    @Test("execute 校验 limit 范围与类型")
    func executeValidatesLimit() async {
        let id = UUID().uuidString
        await #expect(throws: DatabaseAgentToolError.invalidLimit) {
            try await describe.execute(arguments: args(("connection_id", id), ("limit", 0)))
        }
        await #expect(throws: DatabaseAgentToolError.invalidLimit) {
            try await describe.execute(arguments: args(("connection_id", id), ("limit", "abc")))
        }
    }

    @Test("SQL 提案校验目标 UUID 与非空 SQL")
    func proposalValidation() async {
        let connectionID = UUID().uuidString
        let tabID = UUID().uuidString
        let token = UUID().uuidString
        await #expect(throws: DatabaseAgentToolError.missingArgument("query_tab_id")) {
            try await propose.execute(arguments: args(("connection_id", connectionID)))
        }
        await #expect(throws: DatabaseAgentToolError.invalidUUID(argument: "query_tab_id", value: "tab")) {
            try await propose.execute(arguments: args(("connection_id", connectionID), ("query_tab_id", "tab")))
        }
        await #expect(throws: DatabaseAgentToolError.invalidUUID(argument: "proposal_token", value: "token")) {
            try await propose.execute(arguments: args(
                ("connection_id", connectionID),
                ("query_tab_id", tabID),
                ("proposal_token", "token")
            ))
        }
        await #expect(throws: DatabaseAgentToolError.missingArgument("sql")) {
            try await propose.execute(arguments: args(
                ("connection_id", connectionID),
                ("query_tab_id", tabID),
                ("proposal_token", token),
                ("sql", "  \n ")
            ))
        }
    }

    @Test("未知连接在访问阶段被拒绝（不触网），schema 空白视为未提供")
    func unknownConnectionRejected() async {
        let id = UUID().uuidString
        await #expect(throws: DatabaseAgentToolError.connectionNotFound(id)) {
            try await describe.execute(arguments: args(("connection_id", id), ("schema", "  ")))
        }
    }
}
