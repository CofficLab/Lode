import Foundation
import os

/// 可选开启的分级诊断日志，写出前一律经 ``LogRedactor`` 脱敏。
///
/// `debug` 级仅在 ``debugEnabled`` 为真时写出（设置面板的「调试日志」开关）；
/// `info`/`warning`/`error` 始终写出但仍脱敏。消息以 `@autoclosure` 传入，被抑制
/// 时不求值，避免无谓的字符串构造。默认 sink 写入 OSLog；测试可注入捕获 sink。
public final class PluginDebugLog: @unchecked Sendable {
    public enum Level: Int, Sendable, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public typealias Sink = @Sendable (Level, String) -> Void

    private let lock = NSLock()
    private var _debugEnabled: Bool
    private let sink: Sink

    public init(debugEnabled: Bool = false, sink: Sink? = nil) {
        self._debugEnabled = debugEnabled
        self.sink = sink ?? Self.osLogSink
    }

    public var debugEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _debugEnabled
    }

    public func setDebugEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        _debugEnabled = enabled
    }

    public func log(_ level: Level, _ message: @autoclosure () -> String) {
        emit(level, message)
    }

    public func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }
    public func info(_ message: @autoclosure () -> String) { emit(.info, message) }
    public func warning(_ message: @autoclosure () -> String) { emit(.warning, message) }
    public func error(_ message: @autoclosure () -> String) { emit(.error, message) }

    private func emit(_ level: Level, _ message: () -> String) {
        if level == .debug && !debugEnabled { return }
        sink(level, LogRedactor.redact(message()))
    }

    private static let osLogSink: Sink = { level, message in
        let logger = Logger(subsystem: "com.coffic.lumi", category: "DatabaseManagerPlugin")
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}