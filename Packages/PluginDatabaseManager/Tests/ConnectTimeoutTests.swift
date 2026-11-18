import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import DatabaseManagerPlugin

private struct TimeoutError: Error, Equatable {}
private struct ConnectError: Error, Equatable {}

/// dispose 回调经事件循环触发，用锁保护计数。
private final class DisposeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

/// 连接超时竞速：EmbeddedEventLoop 虚拟时钟离线驱动全部路径。
/// EmbeddedEventLoop 非线程安全 —— 所有事件循环操作都必须发生在首个 await 之前。
@Suite(.timeLimit(.minutes(1)))
struct ConnectTimeoutTests {
    @Test("seconds <= 0 直通：不调度超时任务，成功结果原样透传", arguments: [0, -1])
    func passthroughSuccess(seconds: Int) async throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Int.self)
        let disposed = DisposeCounter()
        let raced = ConnectTimeout.race(
            promise.futureResult,
            seconds: seconds,
            on: loop,
            error: { TimeoutError() },
            dispose: { _ in disposed.bump() }
        )
        // 若实现错误地调度了超时任务，这里会先以超时失败并在 succeed 时 trap。
        loop.advanceTime(by: .seconds(60))
        promise.succeed(42)
        #expect(try await raced.get() == 42)
        #expect(disposed.value == 0)
    }

    @Test("seconds <= 0 直通：失败结果原样透传")
    func passthroughFailure() async throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Int.self)
        let raced = ConnectTimeout.race(
            promise.futureResult,
            seconds: 0,
            on: loop,
            error: { TimeoutError() },
            dispose: { _ in }
        )
        promise.fail(ConnectError())
        await #expect(throws: ConnectError.self) { try await raced.get() }
    }

    @Test("连接先于截止时间到达：透传成功、不 dispose、超时任务已取消")
    func connectionWinsBeforeDeadline() async throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: String.self)
        let disposed = DisposeCounter()
        let raced = ConnectTimeout.race(
            promise.futureResult,
            seconds: 5,
            on: loop,
            error: { TimeoutError() },
            dispose: { _ in disposed.bump() }
        )
        promise.succeed("connected")
        // 超时任务已被 whenComplete 取消，推进时间不应触发任何动作。
        loop.advanceTime(by: .seconds(10))
        #expect(try await raced.get() == "connected")
        #expect(disposed.value == 0)
    }

    @Test("连接先失败：透传原始错误而非超时错误")
    func connectionFailureWins() async throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: String.self)
        let raced = ConnectTimeout.race(
            promise.futureResult,
            seconds: 5,
            on: loop,
            error: { TimeoutError() },
            dispose: { _ in }
        )
        promise.fail(ConnectError())
        loop.advanceTime(by: .seconds(10))
        await #expect(throws: ConnectError.self) { try await raced.get() }
    }

    @Test("超时先到：以超时错误失败，迟到的成功连接被 dispose")
    func timeoutWinsAndLateConnectionDisposed() async throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: String.self)
        let disposed = DisposeCounter()
        let raced = ConnectTimeout.race(
            promise.futureResult,
            seconds: 2,
            on: loop,
            error: { TimeoutError() },
            dispose: { _ in disposed.bump() }
        )
        loop.advanceTime(by: .seconds(3))
        // 迟到的成功连接必须关闭，避免半开连接泄漏。
        promise.succeed("late")
        await #expect(throws: TimeoutError.self) { try await raced.get() }
        #expect(disposed.value == 1)
    }

    @Test("超时先到：迟到的失败不改写超时错误")
    func lateFailureAfterTimeoutKeepsTimeoutError() async throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: String.self)
        let disposed = DisposeCounter()
        let raced = ConnectTimeout.race(
            promise.futureResult,
            seconds: 2,
            on: loop,
            error: { TimeoutError() },
            dispose: { _ in disposed.bump() }
        )
        loop.advanceTime(by: .seconds(3))
        // 输入 future 仍未落定，失败它不影响竞速结果（RaceState 已被超时方占据）。
        promise.fail(ConnectError())
        await #expect(throws: TimeoutError.self) { try await raced.get() }
        #expect(disposed.value == 0)
    }
}
