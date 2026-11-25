import Foundation
import Testing
@testable import DatabaseManagerPlugin

// 需要本地 Docker 引擎：设置 LODE_TEST_MYSQL_PORT 后启用。
// MySQL: root/test + testdb。

@Suite(.timeLimit(.minutes(1)))
struct MySQLCloseDrainIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"] != nil))
    func closeWaitsForInFlightPreparedStatement() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"].flatMap(Int.init))
        let conn = try await MySQLConnection(
            host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb"
        )
        // execute 走预处理协议；这里确保关闭发生时 statement 已进入执行阶段。
        let query = Task {
            try? await conn.execute("SELECT SLEEP(10)", params: nil)
        }
        try await Task.sleep(for: .milliseconds(300))

        await conn.close()

        #expect(await conn.isAlive() == false)
        _ = await query.value
    }
}