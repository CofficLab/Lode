import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// 跨线程收集异步查询结局，供取消测试轮询。
final class QueryOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Result<Void, Error>?

    var value: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ value: Result<Void, Error>) {
        lock.lock()
        _value = value
        lock.unlock()
    }
}

@Suite(.timeLimit(.minutes(2)))
struct SQLiteCancellationTests {
    /// 递归 CTE 计数 20 亿行，正常执行需要数分钟，保证取消窗口足够大。
    private let slowSQL = """
    WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 2000000000)
    SELECT COUNT(*) FROM seq
    """

    @Test func cancelInterruptsRunningQuery() async throws {
        let conn = try SQLiteConnection(path: ":memory:")
        let outcome = QueryOutcomeBox()
        let task = Task {
            do {
                _ = try await conn.query(slowSQL, params: nil)
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
        }

        // 持续 interrupt 直到运行中的语句响应，规避「语句还没开始就被取消」的竞态。
        for _ in 0..<200 {
            if outcome.value != nil { break }
            await conn.cancel()
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()

        guard case .failure(let error)? = outcome.value else {
            Issue.record("Slow query was not cancelled")
            await conn.close()
            return
        }
        guard let dbError = error as? DatabaseError, case .cancelled = dbError else {
            Issue.record("Expected DatabaseError.cancelled, got \(error)")
            await conn.close()
            return
        }

        let result = try await conn.query("SELECT 1 AS one", params: nil)
        #expect(result.rows == [[.integer(1)]])
        await conn.close()
    }

    @Test func cancelInterruptsRunningExecute() async throws {
        let conn = try SQLiteConnection(path: ":memory:")
        let slowWrite = """
        CREATE TABLE slow AS
        WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 2000000000)
        SELECT x FROM seq
        """
        let outcome = QueryOutcomeBox()
        let task = Task {
            do {
                _ = try await conn.execute(slowWrite, params: nil)
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
        }

        for _ in 0..<200 {
            if outcome.value != nil { break }
            await conn.cancel()
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()

        guard case .failure(let error)? = outcome.value else {
            Issue.record("Slow execute was not cancelled")
            await conn.close()
            return
        }
        guard let dbError = error as? DatabaseError, case .cancelled = dbError else {
            Issue.record("Expected DatabaseError.cancelled, got \(error)")
            await conn.close()
            return
        }

        let result = try await conn.query("SELECT 1 AS one", params: nil)
        #expect(result.rows == [[.integer(1)]])
        await conn.close()
    }

    @Test func cancelWhileIdleIsNoOp() async throws {
        let conn = try SQLiteConnection(path: ":memory:")
        await conn.cancel()
        let result = try await conn.query("SELECT 42 AS v", params: nil)
        #expect(result.rows == [[.integer(42)]])
        await conn.close()
    }
}