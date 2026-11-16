import Foundation
import Testing
@testable import DatabaseManagerPlugin

// 需要本地 Docker 引擎：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT / LODE_TEST_REDIS_PORT 后启用。
// MySQL: root/test + testdb；PostgreSQL: postgres/test + testdb；Redis 无密码。

private func testPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@Suite(.timeLimit(.minutes(3)))
struct DriverCancellationIntegrationTests {
    private static func expectCancelled(_ outcome: QueryOutcomeBox) {
        guard case .failure(let error)? = outcome.value else {
            Issue.record("Slow query was not cancelled")
            return
        }
        guard let dbError = error as? DatabaseError, case .cancelled = dbError else {
            Issue.record("Expected DatabaseError.cancelled, got \(error)")
            return
        }
    }

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlCancelKillsQueryAndKeepsConnection() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        let conn = try await MySQLConnection(
            host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb"
        )
        // SLEEP/BENCHMARK 被 KILL QUERY 时都会正常返回而不是报错（已在 MySQL 8 实测），
        // 只有递归 CTE 这类执行器会抛出 1317 QUERY_INTERRUPTED。
        _ = try await conn.execute("SET SESSION cte_max_recursion_depth = 1000000000", params: nil)
        let outcome = QueryOutcomeBox()
        let task = Task {
            do {
                _ = try await conn.query(
                    "WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 1000000000) SELECT COUNT(*) FROM seq",
                    params: nil
                )
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
        }

        for _ in 0..<100 {
            if outcome.value != nil { break }
            await conn.cancel()
            try await Task.sleep(for: .milliseconds(100))
        }
        task.cancel()
        Self.expectCancelled(outcome)

        let result = try await conn.query("SELECT 1 AS one", params: nil)
        #expect(result.rows.first?.first == .integer(1))
        await conn.close()
    }

    @Test(.enabled(if: testPort("LODE_TEST_PG_PORT") != nil))
    func postgresCancelKillsQueryAndKeepsConnection() async throws {
        let port = try #require(testPort("LODE_TEST_PG_PORT"))
        let conn = try await PGConnection(
            host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb"
        )
        let outcome = QueryOutcomeBox()
        let task = Task {
            do {
                _ = try await conn.query("SELECT pg_sleep(30)", params: nil)
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
        }

        for _ in 0..<100 {
            if outcome.value != nil { break }
            await conn.cancel()
            try await Task.sleep(for: .milliseconds(100))
        }
        task.cancel()
        Self.expectCancelled(outcome)

        let result = try await conn.query("SELECT 1 AS one", params: nil)
        #expect(result.rows.first?.first == .integer(1))
        await conn.close()
    }

    @Test(.enabled(if: testPort("LODE_TEST_REDIS_PORT") != nil))
    func redisCancelDisconnectsBlockingCommand() async throws {
        let port = try #require(testPort("LODE_TEST_REDIS_PORT"))
        let conn = try await RedisConnection(host: "127.0.0.1", port: port)
        let outcome = QueryOutcomeBox()
        let task = Task {
            do {
                _ = try await conn.query("BLPOP lode_cancel_missing_key 30", params: nil)
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
        }

        for _ in 0..<100 {
            if outcome.value != nil { break }
            await conn.cancel()
            try await Task.sleep(for: .milliseconds(100))
        }
        task.cancel()
        Self.expectCancelled(outcome)

        // Redis 取消即断开：连接不再可用，需要重连。
        #expect(await conn.isAlive() == false)
        await conn.close()
    }
}