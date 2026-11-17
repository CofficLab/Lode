import Foundation
import SQLite3
import Testing
@testable import DatabaseManagerPlugin

// SQLite 并发写入回归：一个连接持有写锁时，另一个连接的写入应等待锁释放
// （busy_timeout）后成功，而非立即抛 "database is locked"。
//
// 锁的持有与释放放在一条独立的 OS 线程上，而非协作线程池的 Task：全量并发
// 负载下（如 CI）协作池会被其它同步 sqlite3_step 忙等占满，释放锁的 Task
// 可能数十秒排不上队，等待方耗尽 busy_timeout 后误报 locked（放宽 timeout
// 只是延后失败，治标不治本）。独立线程的 sleep+COMMIT 不依赖协作池，保证锁
// 按时释放；等待方因此只需短暂忙等即可成功，真正考验驱动的 busy_timeout。
@Suite(.timeLimit(.minutes(1)))
struct SQLiteConcurrencyTests {
    // 一次性信号：把 OS 线程的同步 signal 桥接成 async await，避免在异步上下文
    // 调用 DispatchSemaphore.wait（Swift 6 禁止），也不阻塞协作线程。signal 先于
    // wait 时置位立即返回，保证 continuation 恰好恢复一次。
    final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var signaled = false

        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                if signaled {
                    lock.unlock()
                    cont.resume()
                    return
                }
                continuation = cont
                lock.unlock()
            }
        }

        func signal() {
            lock.lock()
            if let cont = continuation {
                continuation = nil
                lock.unlock()
                cont.resume()
            } else {
                signaled = true
                lock.unlock()
            }
        }
    }

    @Test func concurrentWriterWaitsForLock() async throws {
        let path = NSTemporaryDirectory() + "lode-lock-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lockHeld = Signal()
        let released = Signal()
        final class Setup: @unchecked Sendable { var ok = false; var message = "" }
        let setup = Setup()

        // 原始句柄完全限制在这条线程内（开/事务/释放/关），不跨线程共享。
        let holder = Thread {
            var db: OpaquePointer?
            defer {
                if let db { sqlite3_close(db) }
                released.signal()
            }
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                setup.message = "sqlite3_open failed"
                lockHeld.signal()
                return
            }
            // 等待方忙等重试会瞬间持有 SHARED 锁；持有方若无 busy_timeout，
            // COMMIT 可能立即 BUSY 并在 close 时回滚，丢掉持有行导致计数断言抖动。
            sqlite3_busy_timeout(db, 5000)
            for sql in [
                "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)",
                "BEGIN IMMEDIATE",
                "INSERT INTO t (id, v) VALUES (1, 'a')",
            ] {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    setup.message = "setup step failed: \(sql)"
                    lockHeld.signal()
                    return
                }
            }
            setup.ok = true
            lockHeld.signal()
            // 150ms 后释放写锁（独立线程，不受协作池调度影响）。
            Thread.sleep(forTimeInterval: 0.15)
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                setup.ok = false
                setup.message = "holder COMMIT failed"
            }
        }
        holder.name = "lode-sqlite-lock-holder"
        holder.start()

        // 等锁确实持有后再开始等待方写入（signal/wait 提供 happens-before 屏障）。
        await lockHeld.wait()
        try #require(setup.ok, "lock holder setup failed: \(setup.message)")

        let b = try SQLiteConnection(path: path)
        defer { Task { await b.close() } }
        // b 的写入应阻塞等待锁，随后成功（无 busy_timeout 会立即失败）。
        let affected = try await b.execute("INSERT INTO t (id, v) VALUES (2, 'b')", params: nil)
        #expect(affected == 1)
        await released.wait()
        try #require(setup.ok, "lock holder failed: \(setup.message)")

        let count = try await b.query("SELECT COUNT(*) FROM t", params: nil)
        #expect(count.rows.first?.first == .integer(2))
    }
}