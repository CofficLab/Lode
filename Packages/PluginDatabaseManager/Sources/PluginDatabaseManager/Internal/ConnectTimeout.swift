import Foundation
import NIOCore

/// 连接超时竞速：把 connect future 与截止时间赛跑。
///
/// 超时立即失败（错误可被 ``DatabaseErrorClassifier`` 归类为 timeout）；
/// 迟到的连接通过 `dispose` 关闭，避免半开连接泄漏。
///
/// `T` 约束为 `Sendable`（MySQL/Postgres 连接均满足），使结果可跨事件循环安全转移。
enum ConnectTimeout {
    static func race<T: Sendable>(
        _ future: EventLoopFuture<T>,
        seconds: Int,
        on loop: EventLoop,
        error: @escaping @Sendable () -> Error,
        dispose: @escaping @Sendable (T) -> Void
    ) -> EventLoopFuture<T> {
        guard seconds > 0 else { return future }
        let promise = loop.makePromise(of: T.self)
        let state = RaceState()
        let timeoutTask = loop.scheduleTask(in: .seconds(Int64(seconds))) {
            if state.trySettle() {
                promise.fail(error())
            }
        }
        future.whenComplete { result in
            timeoutTask.cancel()
            if state.trySettle() {
                promise.completeWith(result)
            } else if case .success(let value) = result {
                // 超时已先失败：迟到的成功连接必须关闭，避免半开连接泄漏。
                dispose(value)
            }
        }
        return promise.futureResult
    }

    private final class RaceState: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false

        /// 第一个落定者赢；返回 true 表示调用方赢得竞速。
        func trySettle() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if settled { return false }
            settled = true
            return true
        }
    }
}