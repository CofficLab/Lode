import Foundation
import Testing
@testable import DatabaseManagerPlugin

// 需要本地 Docker 引擎：设置 LODE_TEST_MYSQL_PORT / LODE_TEST_PG_PORT / LODE_TEST_REDIS_PORT 后启用。
// 验证真实失败路径的错误分类：错误密码、不存在的库、语法错误、不可达端口、无权限用户。

private func testPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func expectCategory(_ expected: DatabaseErrorCategory, of error: any Error) {
    let classified = DatabaseErrorClassifier.classify(error)
    #expect(classified.category == expected, "expected \(expected), got \(classified.category) for: \(error)")
}

@Suite(.timeLimit(.minutes(3)))
struct ErrorClassificationIntegrationTests {
    // MARK: - MySQL

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlWrongPasswordIsAuthentication() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        do {
            let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "wrong-password", database: "testdb")
            await conn.close()
            Issue.record("Expected authentication failure")
        } catch {
            expectCategory(.authenticationFailed, of: error)
        }
    }

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlUnknownDatabaseIsDatabaseNotFound() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        do {
            let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "lode_no_such_db")
            await conn.close()
            Issue.record("Expected unknown-database failure")
        } catch {
            expectCategory(.databaseNotFound, of: error)
        }
    }

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlSyntaxErrorIsSyntax() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        do {
            _ = try await conn.query("SELEC 1", params: nil)
            Issue.record("Expected syntax error")
        } catch {
            expectCategory(.syntaxError, of: error)
        }
        await conn.close()
    }

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlUnreachablePortIsNetwork() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        do {
            let conn = try await MySQLConnection(host: "127.0.0.1", port: port + 1000, username: "root", password: "test", database: "testdb")
            await conn.close()
            Issue.record("Expected connection failure on closed port")
        } catch {
            expectCategory(.networkUnreachable, of: error)
        }
    }

    @Test(.enabled(if: testPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlUnprivilegedUserIsPermissionDenied() async throws {
        let port = try #require(testPort("LODE_TEST_MYSQL_PORT"))
        let admin = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        _ = try await admin.execute("CREATE USER IF NOT EXISTS 'lode_noperm'@'%' IDENTIFIED BY 'test'", params: nil)
        await admin.close()
        do {
            let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "lode_noperm", password: "test", database: "testdb")
            await conn.close()
            Issue.record("Expected permission failure")
        } catch {
            expectCategory(.permissionDenied, of: error)
        }
        let cleanup = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        _ = try await cleanup.execute("DROP USER IF EXISTS 'lode_noperm'@'%'", params: nil)
        await cleanup.close()
    }

    // MARK: - PostgreSQL

    @Test(.enabled(if: testPort("LODE_TEST_PG_PORT") != nil))
    func pgWrongPasswordIsAuthentication() async throws {
        let port = try #require(testPort("LODE_TEST_PG_PORT"))
        do {
            let conn = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "wrong-password", database: "testdb")
            await conn.close()
            Issue.record("Expected authentication failure")
        } catch {
            expectCategory(.authenticationFailed, of: error)
        }
    }

    @Test(.enabled(if: testPort("LODE_TEST_PG_PORT") != nil))
    func pgUnknownDatabaseIsDatabaseNotFound() async throws {
        let port = try #require(testPort("LODE_TEST_PG_PORT"))
        do {
            let conn = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "lode_no_such_db")
            await conn.close()
            Issue.record("Expected unknown-database failure")
        } catch {
            expectCategory(.databaseNotFound, of: error)
        }
    }

    @Test(.enabled(if: testPort("LODE_TEST_PG_PORT") != nil))
    func pgSyntaxErrorIsSyntax() async throws {
        let port = try #require(testPort("LODE_TEST_PG_PORT"))
        let conn = try await PGConnection(host: "127.0.0.1", port: port, username: "postgres", password: "test", database: "testdb")
        do {
            _ = try await conn.query("SELEC 1", params: nil)
            Issue.record("Expected syntax error")
        } catch {
            expectCategory(.syntaxError, of: error)
        }
        await conn.close()
    }

    @Test(.enabled(if: testPort("LODE_TEST_PG_PORT") != nil))
    func pgUnreachablePortIsNetwork() async throws {
        let port = try #require(testPort("LODE_TEST_PG_PORT"))
        do {
            let conn = try await PGConnection(host: "127.0.0.1", port: port + 1000, username: "postgres", password: "test", database: "testdb")
            await conn.close()
            Issue.record("Expected connection failure on closed port")
        } catch {
            expectCategory(.networkUnreachable, of: error)
        }
    }

    // MARK: - Redis

    @Test(.enabled(if: testPort("LODE_TEST_REDIS_PORT") != nil))
    func redisUnreachablePortIsNetwork() async throws {
        let port = try #require(testPort("LODE_TEST_REDIS_PORT"))
        do {
            let conn = try await RedisConnection(host: "127.0.0.1", port: port + 1000)
            await conn.close()
            Issue.record("Expected connection failure on closed port")
        } catch {
            expectCategory(.networkUnreachable, of: error)
        }
    }
}