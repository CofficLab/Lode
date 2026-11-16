import Foundation
import Testing
@testable import DatabaseManagerPlugin

// MySQL 预处理协议不支持 CREATE/DROP TRIGGER、CREATE PROCEDURE/FUNCTION 等语句
// （ER_UNSUPPORTED_PS）。无绑定参数时驱动应回退文本协议；参数化执行不受影响。

@Suite(.serialized)
struct MySQLTextProtocolFallbackTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"] != nil))
    func executeFallsBackToTextProtocolForUnsupportedStatements() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LODE_TEST_MYSQL_PORT"].flatMap(Int.init))
        let conn = try await MySQLConnection(host: "127.0.0.1", port: port, username: "root", password: "test", database: "testdb")
        defer { Task { await conn.close() } }
        _ = try? await conn.execute("SET GLOBAL log_bin_trust_function_creators = 1", params: nil)
        _ = try await conn.execute("DROP TRIGGER IF EXISTS fb_trg", params: nil)
        _ = try await conn.execute("DROP PROCEDURE IF EXISTS fb_proc", params: nil)
        _ = try await conn.execute("DROP FUNCTION IF EXISTS fb_fn", params: nil)
        _ = try await conn.execute("DROP TABLE IF EXISTS fb_t", params: nil)
        _ = try await conn.execute("CREATE TABLE fb_t (id INTEGER PRIMARY KEY, v VARCHAR(32))", params: nil)
        defer {
            Task {
                _ = try? await conn.execute("DROP TRIGGER IF EXISTS fb_trg", params: nil)
                _ = try? await conn.execute("DROP PROCEDURE IF EXISTS fb_proc", params: nil)
                _ = try? await conn.execute("DROP FUNCTION IF EXISTS fb_fn", params: nil)
                _ = try? await conn.execute("DROP TABLE IF EXISTS fb_t", params: nil)
            }
        }

        _ = try await conn.execute(
            "CREATE TRIGGER fb_trg BEFORE INSERT ON fb_t FOR EACH ROW SET NEW.v = LOWER(NEW.v)", params: nil)
        _ = try await conn.execute("CREATE PROCEDURE fb_proc() BEGIN SELECT 1; END", params: nil)
        _ = try await conn.execute("CREATE FUNCTION fb_fn() RETURNS INT DETERMINISTIC RETURN 7", params: nil)

        // 参数化执行仍走预处理协议：触发器把写入值转为小写。
        _ = try await conn.execute("INSERT INTO fb_t (id, v) VALUES (?, ?)", params: [.integer(1), .string("ABC")])
        let result = try await conn.query("SELECT v FROM fb_t WHERE id = ?", params: [.integer(1)])
        #expect(SchemaRowDecoder.string(result.rows.first ?? [], at: 0) == "abc")

        // 例程可调用，证明创建真实生效。
        let fnResult = try await conn.query("SELECT fb_fn()", params: nil)
        #expect(SchemaRowDecoder.int(fnResult.rows.first ?? [], at: 0) == 7)
    }
}