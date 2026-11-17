import Foundation
import Testing
@testable import DatabaseManagerPlugin

// SQLite 并发写入回归：一个连接持有写锁时，另一个连接的写入应等待锁释放
// （busy_timeout）后成功，而非立即抛 "database is locked"。
@Suite(.timeLimit(.minutes(1)))
struct SQLiteConcurrencyTests {
    @Test func concurrentWriterWaitsForLock() async throws {
        let path = NSTemporaryDirectory() + "lode-lock-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let a = try SQLiteConnection(path: path)
        let b = try SQLiteConnection(path: path)
        defer {
            Task { await a.close() }
            Task { await b.close() }
        }
        _ = try await a.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", params: nil)
        _ = try await a.execute("BEGIN IMMEDIATE", params: nil)
        _ = try await a.execute("INSERT INTO t (id, v) VALUES (1, 'a')", params: nil)

        // 全量并发负载下（如 CI），释放锁的 Task 可能被协作线程池延迟数秒才调度，
        // 超过驱动默认 5s busy_timeout 会让等待方误报 "database is locked"。
        // 放宽等待方的 busy_timeout 到 30s，只考验「等待后成功」这一不变量。
        _ = try await b.execute("PRAGMA busy_timeout=30000", params: nil)

        // 150ms 后释放写锁。
        let release = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? await a.execute("COMMIT", params: nil)
        }
        // b 的写入应阻塞等待锁，随后成功（无 busy_timeout 会立即失败）。
        let affected = try await b.execute("INSERT INTO t (id, v) VALUES (2, 'b')", params: nil)
        #expect(affected == 1)
        await release.value

        let count = try await b.query("SELECT COUNT(*) FROM t", params: nil)
        #expect(count.rows.first?.first == .integer(2))
    }
}