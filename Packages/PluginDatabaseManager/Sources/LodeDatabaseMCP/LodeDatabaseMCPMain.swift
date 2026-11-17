import DatabaseManagerPlugin
import Foundation

/// lode-db-mcp：把 Lode 的只读数据库工具以 MCP stdio server 暴露给外部 Agent。
///
/// 用法：
///   lode-db-mcp --generate-token   生成/轮换访问令牌（一次性打印）
///   LODE_MCP_TOKEN=<token> lode-db-mcp [--require-consent]
///
/// stdout 只输出 JSON-RPC 消息；诊断信息一律走 stderr。
@main
struct LodeDatabaseMCPMain {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()

        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }

        let tokenStore = DatabaseMCPTokenStore()
        if arguments.contains("--generate-token") {
            do {
                let token = try tokenStore.generate()
                print(token)
            } catch {
                fail("Could not write token file: \(error.localizedDescription)")
            }
            return
        }

        guard (try? tokenStore.load()) != nil else {
            fail("No MCP token configured. Run: lode-db-mcp --generate-token")
        }
        let presented = ProcessInfo.processInfo.environment[DatabaseMCPTokenStore.tokenEnvironmentKey]
        guard tokenStore.verify(presented) else {
            fail("Invalid or missing LODE_MCP_TOKEN. Set it to the token printed by --generate-token.")
        }

        let (service, policy) = await DatabaseMCPBootstrap.makeService()
        let outputLock = NSLock()
        let session = DatabaseMCPSession(
            service: service,
            policy: policy,
            requireConsent: arguments.contains("--require-consent"),
            send: { data in
                outputLock.lock()
                defer { outputLock.unlock() }
                var line = data
                line.append(0x0A)
                try? FileHandle.standardOutput.write(contentsOf: line)
            }
        )

        // stdin 逐行喂入会话；EOF（客户端断开）即退出。
        let lines = AsyncStream<String> { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.name = "lode-db-mcp.stdin"
            thread.start()
        }
        for await line in lines {
            await session.receive(line)
        }
    }

    private static func printUsage() {
        let usage = """
        lode-db-mcp — MCP stdio server exposing Lode's read-only database tools.

        Setup:
          1. lode-db-mcp --generate-token
          2. Configure your MCP client:
             command: lode-db-mcp
             env:     LODE_MCP_TOKEN=<token from step 1>

        Options:
          --generate-token    Create or rotate the access token (printed once).
          --require-consent   Ask for approval via MCP elicitation on every tool call.
          --help              Show this help.

        Security:
          - Read-only tools only; the per-connection Agent Access allowlist is enforced.
          - Sensitive table samples always require interactive approval (elicitation).
          - Errors are redacted; activity is recorded in Lode's agent audit log.
          - LODE_MCP_TOKEN_FILE overrides the token file location.
        """
        print(usage)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}