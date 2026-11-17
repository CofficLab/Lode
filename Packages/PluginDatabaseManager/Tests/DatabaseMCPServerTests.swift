import Testing
import Foundation
@testable import DatabaseManagerPlugin

/// MCP server 的协议、安全与真实进程行为测试。
///
/// 会话测试注入独立 SQLite 夹具与临时偏好域，不触碰 App 真实状态；
/// spawn 测试以隔离偏好域驱动真实二进制走完整 stdio 往返。

private enum MCPTestError: Error {
    case timeout
}

private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func messages() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    func response(id: Int) -> [String: Any]? {
        messages().first { ($0["id"] as? Int) == id }
    }

    func first(where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        messages().first(where: predicate)
    }
}

private func rpcLine(id: Int, method: String, params: [String: Any] = [:]) -> String {
    let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func notificationLine(_ method: String) -> String {
    let object: [String: Any] = ["jsonrpc": "2.0", "method": method]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func responseLine(id: Int, result: [String: Any]) -> String {
    let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func toolCallLine(id: Int, name: String, arguments: [String: Any]) -> String {
    rpcLine(id: id, method: "tools/call", params: ["name": name, "arguments": arguments])
}

private func toolResultText(_ response: [String: Any]) throws -> (text: String, isError: Bool) {
    let result = try #require(response["result"] as? [String: Any])
    let content = try #require(result["content"] as? [[String: Any]])
    let text = try #require(content.first?["text"] as? String)
    return (text, (result["isError"] as? Bool) ?? false)
}

private func errorCode(_ response: [String: Any]) throws -> Int {
    let error = try #require(response["error"] as? [String: Any])
    return try #require(error["code"] as? Int)
}

private func waitForMessage(
    _ box: MessageBox,
    timeout: TimeInterval = 5,
    where predicate: ([String: Any]) -> Bool
) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let message = box.first(where: predicate) { return message }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw MCPTestError.timeout
}

private struct MCPFixture {
    let directory: URL
    let defaultsSuite: String
    let config: DatabaseConfig
    let manager: DatabaseManagerCore
    let policy: DatabaseAgentAccessPolicy
    let audit: DatabaseAgentAuditLog
    let service: DatabaseAgentToolService

    func cleanup() async {
        await manager.disconnect(configId: config.id)
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeMCPFixture() async throws -> MCPFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DatabaseMCPTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "fixture.sqlite")

    let config = DatabaseConfig(id: UUID(), name: "MCPFixture", type: .sqlite, database: url.path)
    let manager = DatabaseManagerCore()
    await manager.register(driver: SQLiteDriver())
    let connection = try await manager.connect(config: config)
    _ = try await connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
    _ = try await connection.execute("INSERT INTO users (name) VALUES ('alice'), ('bob')", params: nil)
    _ = try await connection.execute("CREATE TABLE user_secrets (id INTEGER PRIMARY KEY, value TEXT)", params: nil)
    _ = try await connection.execute("INSERT INTO user_secrets (value) VALUES ('classified')", params: nil)
    await connection.close()

    let suite = "DatabaseMCPTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let registry = DatabaseAgentConnectionRegistry()
    await registry.upsert(config)
    let policy = DatabaseAgentAccessPolicy(defaults: defaults)
    let audit = DatabaseAgentAuditLog(defaults: defaults)
    let service = DatabaseAgentToolService(manager: manager, registry: registry, policy: policy, audit: audit)
    return MCPFixture(
        directory: directory,
        defaultsSuite: suite,
        config: config,
        manager: manager,
        policy: policy,
        audit: audit,
        service: service
    )
}

private func makeSession(
    fixture: MCPFixture,
    requireConsent: Bool = false
) -> (DatabaseMCPSession, MessageBox) {
    let box = MessageBox()
    let session = DatabaseMCPSession(
        service: fixture.service,
        policy: fixture.policy,
        requireConsent: requireConsent,
        send: { box.append($0) }
    )
    return (session, box)
}

private func initializeSession(
    _ session: DatabaseMCPSession,
    elicitation: Bool = true,
    version: String = "2025-06-18"
) async {
    let capabilities: [String: Any] = elicitation ? ["elicitation": [String: Any]()] : [:]
    await session.receive(rpcLine(id: 1, method: "initialize", params: [
        "protocolVersion": version,
        "capabilities": capabilities,
        "clientInfo": ["name": "mcp-tests", "version": "1.0"],
    ]))
    await session.receive(notificationLine("notifications/initialized"))
}

// MARK: - Token store

@Suite struct DatabaseMCPTokenStoreTests {

    private func makeStore() -> (DatabaseMCPTokenStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseMCPToken-\(UUID().uuidString)", isDirectory: true)
        return (DatabaseMCPTokenStore(directory: directory), directory)
    }

    @Test func generateWritesRestrictedFile() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try store.generate()
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(try store.load() == token)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func verifyAcceptsOnlyMatchingToken() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try store.generate()
        #expect(store.verify(token))
        #expect(!store.verify(token + "x"))
        #expect(!store.verify(String(token.dropLast())))
        #expect(!store.verify(nil))
        #expect(!store.verify(""))
    }

    @Test func rotationReplacesToken() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try store.generate()
        let second = try store.generate()
        #expect(first != second)
        #expect(try store.load() == second)
        #expect(!store.verify(first))
        #expect(store.verify(second))
    }

    @Test func missingTokenRejectsEverything() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.load() == nil)
        #expect(!store.verify("anything"))
    }
}

// MARK: - Protocol & tool behavior

@Suite(.serialized) struct DatabaseMCPSessionProtocolTests {

    @Test func initializeNegotiatesVersionAndListsTools() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session, version: "2024-11-05")

        let initResponse = try #require(box.response(id: 1))
        let result = try #require(initResponse["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2024-11-05")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == DatabaseMCPSession.serverName)
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil)

        await session.receive(rpcLine(id: 2, method: "tools/list"))
        let listResponse = try #require(box.response(id: 2))
        let listResult = try #require(listResponse["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.count == 4)
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(DatabaseMCPSession.toolNames))
        for tool in tools {
            let annotations = try #require(tool["annotations"] as? [String: Any])
            #expect(annotations["readOnlyHint"] as? Bool == true)
            #expect(tool["inputSchema"] != nil)
        }
    }

    @Test func unknownProtocolVersionFallsBackToLatest() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session, version: "1999-01-01")
        let result = try #require(box.response(id: 1)?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
    }

    @Test func pingUnknownMethodAndParseError() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)

        await session.receive(rpcLine(id: 2, method: "ping"))
        #expect(try #require(box.response(id: 2))["result"] != nil)

        await session.receive(rpcLine(id: 3, method: "bogus/method"))
        #expect(try errorCode(try #require(box.response(id: 3))) == -32601)

        await session.receive("{{{ not json")
        let parseError = try #require(box.first { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 })
        #expect(parseError["id"] is NSNull)
    }

    @Test func requestsBeforeInitializeAreRejected() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await session.receive(rpcLine(id: 9, method: "tools/list"))
        #expect(try errorCode(try #require(box.response(id: 9))) == -32002)
    }

    @Test func queryRoundTripAgainstRealSQLite() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)

        await session.receive(toolCallLine(id: 2, name: "database_query_readonly", arguments: [
            "connection_id": fixture.config.id.uuidString,
            "sql": "SELECT name FROM users ORDER BY id",
            "limit": 10,
        ]))
        let (text, isError) = try toolResultText(try #require(box.response(id: 2)))
        #expect(!isError)
        #expect(text.contains("alice"))
        #expect(text.contains("bob"))
        #expect(fixture.audit.recent().contains { $0.tool == "database_query_readonly" && $0.outcome == "ok" })
    }

    @Test func listDescribeAndSample() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)
        let id = fixture.config.id.uuidString

        await session.receive(toolCallLine(id: 2, name: "database_list_connections", arguments: [:]))
        let (listText, listError) = try toolResultText(try #require(box.response(id: 2)))
        #expect(!listError)
        #expect(listText.contains(id))

        await session.receive(toolCallLine(id: 3, name: "database_describe_schema", arguments: ["connection_id": id, "limit": 50]))
        let (schemaText, schemaError) = try toolResultText(try #require(box.response(id: 3)))
        #expect(!schemaError)
        #expect(schemaText.contains("users"))

        await session.receive(toolCallLine(id: 4, name: "database_sample_table", arguments: ["connection_id": id, "table": "users", "limit": 5]))
        let (sampleText, sampleError) = try toolResultText(try #require(box.response(id: 4)))
        #expect(!sampleError)
        #expect(sampleText.contains("alice"))
    }

    @Test func blockedConnectionIsHiddenAndRejected() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)
        let id = fixture.config.id.uuidString
        fixture.policy.setAllowed(false, for: fixture.config.id)

        await session.receive(toolCallLine(id: 2, name: "database_list_connections", arguments: [:]))
        let (listText, _) = try toolResultText(try #require(box.response(id: 2)))
        #expect(!listText.contains(id))

        await session.receive(toolCallLine(id: 3, name: "database_query_readonly", arguments: ["connection_id": id, "sql": "SELECT 1"]))
        let (text, isError) = try toolResultText(try #require(box.response(id: 3)))
        #expect(isError)
        #expect(text.contains("disabled"))
        #expect(fixture.audit.recent().contains { $0.outcome == "denied" })
    }

    @Test func writeSQLIsRejected() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)

        await session.receive(toolCallLine(id: 2, name: "database_query_readonly", arguments: [
            "connection_id": fixture.config.id.uuidString,
            "sql": "DELETE FROM users",
        ]))
        let (text, isError) = try toolResultText(try #require(box.response(id: 2)))
        #expect(isError)
        #expect(text.contains("read-only"))
    }

    @Test func missingArgumentIsToolError() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)

        await session.receive(toolCallLine(id: 2, name: "database_query_readonly", arguments: [
            "connection_id": fixture.config.id.uuidString,
        ]))
        let (text, isError) = try toolResultText(try #require(box.response(id: 2)))
        #expect(isError)
        #expect(text.contains("sql"))
    }

    @Test func unknownToolIsInvalidParams() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)
        await session.receive(toolCallLine(id: 2, name: "bogus_tool", arguments: [:]))
        #expect(try errorCode(try #require(box.response(id: 2))) == -32602)
    }

    @Test func errorTextIsRedacted() {
        let redacted = DatabaseMCPSession.redacted("connection failed: password=hunter2;")
        #expect(redacted.contains(LogRedactor.marker))
        #expect(!redacted.contains("hunter2"))
    }
}

// MARK: - Elicitation consent

@Suite(.serialized) struct DatabaseMCPElicitationTests {

    private func sensitiveCallArguments(_ fixture: MCPFixture) -> [String: Any] {
        ["connection_id": fixture.config.id.uuidString, "table": "user_secrets", "limit": 5]
    }

    @Test func sensitiveSampleAsksApprovalAndProceeds() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)

        let call = Task {
            await session.receive(toolCallLine(id: 5, name: "database_sample_table", arguments: sensitiveCallArguments(fixture)))
        }
        let elicitation = try await waitForMessage(box) { ($0["method"] as? String) == "elicitation/create" }
        let requestID = try #require(elicitation["id"] as? Int)
        let params = try #require(elicitation["params"] as? [String: Any])
        #expect((params["message"] as? String)?.contains("user_secrets") == true)
        #expect(params["requestedSchema"] != nil)

        await session.receive(responseLine(id: requestID, result: ["action": "accept", "content": ["approved": true]]))
        await call.value

        let (text, isError) = try toolResultText(try #require(box.response(id: 5)))
        #expect(!isError)
        #expect(text.contains("classified"))
    }

    @Test func declineBlocksExecution() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)

        let call = Task {
            await session.receive(toolCallLine(id: 5, name: "database_sample_table", arguments: sensitiveCallArguments(fixture)))
        }
        let elicitation = try await waitForMessage(box) { ($0["method"] as? String) == "elicitation/create" }
        let requestID = try #require(elicitation["id"] as? Int)
        await session.receive(responseLine(id: requestID, result: ["action": "decline"]))
        await call.value

        let (text, isError) = try toolResultText(try #require(box.response(id: 5)))
        #expect(isError)
        #expect(text.contains("declined"))
        #expect(!fixture.audit.recent().contains { $0.tool == "database_sample_table" })
    }

    @Test func acceptWithoutApprovedFlagBlocks() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)

        let call = Task {
            await session.receive(toolCallLine(id: 5, name: "database_sample_table", arguments: sensitiveCallArguments(fixture)))
        }
        let elicitation = try await waitForMessage(box) { ($0["method"] as? String) == "elicitation/create" }
        let requestID = try #require(elicitation["id"] as? Int)
        await session.receive(responseLine(id: requestID, result: ["action": "accept", "content": ["approved": false]]))
        await call.value

        let (_, isError) = try toolResultText(try #require(box.response(id: 5)))
        #expect(isError)
    }

    @Test func sensitiveSampleWithoutElicitationSupportIsRejected() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session, elicitation: false)

        await session.receive(toolCallLine(id: 5, name: "database_sample_table", arguments: sensitiveCallArguments(fixture)))
        let (text, isError) = try toolResultText(try #require(box.response(id: 5)))
        #expect(isError)
        #expect(text.contains("elicitation"))
        #expect(box.first { ($0["method"] as? String) == "elicitation/create" } == nil)
        #expect(!fixture.audit.recent().contains { $0.tool == "database_sample_table" })
    }

    @Test func requireConsentModeAsksOnEveryCall() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture, requireConsent: true)
        await initializeSession(session)

        let call = Task {
            await session.receive(toolCallLine(id: 5, name: "database_query_readonly", arguments: [
                "connection_id": fixture.config.id.uuidString,
                "sql": "SELECT name FROM users ORDER BY id",
            ]))
        }
        let elicitation = try await waitForMessage(box) { ($0["method"] as? String) == "elicitation/create" }
        let requestID = try #require(elicitation["id"] as? Int)
        await session.receive(responseLine(id: requestID, result: ["action": "accept", "content": ["approved": true]]))
        await call.value

        let (text, isError) = try toolResultText(try #require(box.response(id: 5)))
        #expect(!isError)
        #expect(text.contains("alice"))
    }

    @Test func ordinarySampleSkipsConsent() async throws {
        let fixture = try await makeMCPFixture()
        defer { Task { await fixture.cleanup() } }
        let (session, box) = makeSession(fixture: fixture)
        await initializeSession(session)

        await session.receive(toolCallLine(id: 5, name: "database_sample_table", arguments: [
            "connection_id": fixture.config.id.uuidString,
            "table": "users",
            "limit": 5,
        ]))
        let (text, isError) = try toolResultText(try #require(box.response(id: 5)))
        #expect(!isError)
        #expect(text.contains("alice"))
        #expect(box.first { ($0["method"] as? String) == "elicitation/create" } == nil)
    }
}

// MARK: - Real process over stdio

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []

    init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.buffer.append(data)
            while let range = self.buffer.firstRange(of: Data([0x0A])) {
                let lineData = self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound)
                self.buffer.removeSubrange(self.buffer.startIndex..<range.upperBound)
                if let line = String(data: lineData, encoding: .utf8),
                   !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.lines.append(line)
                }
            }
        }
    }

    func nextLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                return line
            }
            lock.unlock()
            usleep(10_000)
        }
        return nil
    }

    func nextJSON(timeout: TimeInterval = 15) throws -> [String: Any] {
        guard let line = nextLine(timeout: timeout),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            throw MCPTestError.timeout
        }
        return object
    }
}

@Suite(.serialized) struct DatabaseMCPSpawnTests {

    /// swift test 会构建包内 executable；兼容不同 SwiftPM 产物布局。
    private static func findBinary() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            ".build/debug/lode-db-mcp",
            ".build/out/Products/Debug/lode-db-mcp",
            ".build/arm64-apple-macosx/debug/lode-db-mcp",
        ]
        return candidates
            .map { root.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func makeEnvironment(token: String, tokenFile: URL, domain: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[DatabaseMCPTokenStore.tokenEnvironmentKey] = token
        environment[DatabaseMCPTokenStore.tokenFileEnvironmentKey] = tokenFile.path
        environment[DatabaseMCPBootstrap.appDomainEnvironmentKey] = domain
        return environment
    }

    private func runProcess(_ binary: URL, environment: [String: String], arguments: [String] = []) throws -> (Process, Pipe, Pipe, Pipe) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return (process, stdin, stdout, stderr)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning { process.terminate() }
    }

    @Test func stdioHandshakeQueryAndShutdown() async throws {
        let binary = try #require(Self.findBinary())
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseMCPSpawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // 隔离偏好域 + 一个 SQLite 连接：spawn 进程经应用域装配路径读取。
        let domain = "DatabaseMCPSpawnTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let config = DatabaseConfig(id: UUID(), name: "SpawnFixture", type: .sqlite, database: temp.appending(path: "spawn.sqlite").path)
        let manager = DatabaseManagerCore()
        await manager.register(driver: SQLiteDriver())
        let connection = try await manager.connect(config: config)
        _ = try await connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)", params: nil)
        _ = try await connection.execute("INSERT INTO items (label) VALUES ('spawn-row')", params: nil)
        await connection.close()
        await manager.disconnect(configId: config.id)
        var stored = config
        stored.password = nil
        defaults.set(try JSONEncoder().encode([stored]), forKey: "DatabaseManager.savedConfigs")
        defaults.synchronize()

        let token = "spawn-token-\(UUID().uuidString)"
        let tokenFile = temp.appending(path: "token")
        try Data(token.utf8).write(to: tokenFile)

        let (process, stdin, stdout, _) = try runProcess(binary, environment: makeEnvironment(token: token, tokenFile: tokenFile, domain: domain))
        defer { if process.isRunning { process.terminate() } }
        let collector = LineCollector(handle: stdout.fileHandleForReading)
        func send(_ line: String) throws {
            try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }

        try send(rpcLine(id: 1, method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "spawn-tests", "version": "1.0"],
        ]))
        let initResult = try #require(try collector.nextJSON()["result"] as? [String: Any])
        #expect(initResult["protocolVersion"] as? String == "2025-06-18")
        #expect((initResult["serverInfo"] as? [String: Any])?["name"] as? String == DatabaseMCPSession.serverName)

        try send(notificationLine("notifications/initialized"))
        try send(rpcLine(id: 2, method: "tools/list"))
        let listResult = try #require(try collector.nextJSON()["result"] as? [String: Any])
        #expect((listResult["tools"] as? [[String: Any]])?.count == 4)

        try send(toolCallLine(id: 3, name: "database_query_readonly", arguments: [
            "connection_id": config.id.uuidString,
            "sql": "SELECT label FROM items",
            "limit": 5,
        ]))
        let callResponse = try collector.nextJSON()
        let (text, isError) = try toolResultText(callResponse)
        #expect(!isError)
        #expect(text.contains("spawn-row"))

        try send(rpcLine(id: 4, method: "bogus/method"))
        #expect(try errorCode(try collector.nextJSON()) == -32601)

        try stdin.fileHandleForWriting.close()
        waitForExit(process)
        #expect(!process.isRunning)
        #expect(process.terminationStatus == 0)
    }

    @Test func wrongTokenIsRejected() throws {
        let binary = try #require(Self.findBinary())
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseMCPSpawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tokenFile = temp.appending(path: "token")
        try Data("real-token".utf8).write(to: tokenFile)

        let (process, _, _, stderr) = try runProcess(
            binary,
            environment: makeEnvironment(token: "wrong-token", tokenFile: tokenFile, domain: "DatabaseMCPSpawnTests-unused")
        )
        waitForExit(process)
        #expect(process.terminationStatus == 1)
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(message.contains("LODE_MCP_TOKEN"))
    }

    @Test func missingTokenFileIsRejected() throws {
        let binary = try #require(Self.findBinary())
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseMCPSpawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let (process, _, _, stderr) = try runProcess(
            binary,
            environment: makeEnvironment(token: "any", tokenFile: temp.appending(path: "absent"), domain: "DatabaseMCPSpawnTests-unused")
        )
        waitForExit(process)
        #expect(process.terminationStatus == 1)
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(message.contains("--generate-token"))
    }

    @Test func generateTokenCommandPrintsOnce() throws {
        let binary = try #require(Self.findBinary())
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseMCPSpawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tokenFile = temp.appending(path: "token")

        var environment = ProcessInfo.processInfo.environment
        environment[DatabaseMCPTokenStore.tokenFileEnvironmentKey] = tokenFile.path
        let (process, _, stdout, _) = try runProcess(binary, environment: environment, arguments: ["--generate-token"])
        waitForExit(process)
        #expect(process.terminationStatus == 0)
        let printed = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(printed.count == 64)
        #expect(try String(contentsOf: tokenFile, encoding: .utf8) == printed)
    }
}