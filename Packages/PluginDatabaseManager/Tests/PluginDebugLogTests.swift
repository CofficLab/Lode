import Foundation
import Testing

@testable import DatabaseManagerPlugin

@Suite("PluginDebugLog")
struct PluginDebugLogTests {
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [(level: PluginDebugLog.Level, text: String)] = []
        var messages: [(level: PluginDebugLog.Level, text: String)] {
            lock.lock(); defer { lock.unlock() }
            return _messages
        }
        func append(_ level: PluginDebugLog.Level, _ text: String) {
            lock.lock(); defer { lock.unlock() }
            _messages.append((level, text))
        }
    }

    private func makeLog(enabled: Bool) -> (PluginDebugLog, Capture) {
        let capture = Capture()
        let log = PluginDebugLog(debugEnabled: enabled) { level, text in
            capture.append(level, text)
        }
        return (log, capture)
    }

    @Test func debugIsSuppressedWhenDisabled() {
        let (log, capture) = makeLog(enabled: false)
        log.debug("detail")
        #expect(capture.messages.isEmpty)
    }

    @Test func debugIsEmittedWhenEnabled() {
        let (log, capture) = makeLog(enabled: true)
        log.debug("detail")
        #expect(capture.messages.count == 1)
        #expect(capture.messages.first?.level == .debug)
        #expect(capture.messages.first?.text == "detail")
    }

    @Test func infoWarningErrorAlwaysEmitRegardlessOfToggle() {
        for enabled in [false, true] {
            let (log, capture) = makeLog(enabled: enabled)
            log.info("i")
            log.warning("w")
            log.error("e")
            #expect(capture.messages.map(\.level) == [.info, .warning, .error])
        }
    }

    @Test func emittedMessagesAreRedacted() {
        let (log, capture) = makeLog(enabled: true)
        log.debug("password=hunter2")
        log.info("mysql://root:hunter2@db")
        log.error("token=abc")
        #expect(capture.messages.allSatisfy { !$0.text.contains("hunter2") && !$0.text.contains("abc") })
        #expect(capture.messages[0].text == "password=\(LogRedactor.marker)")
    }

    @Test func suppressedDebugDoesNotEvaluateMessage() {
        let (log, capture) = makeLog(enabled: false)
        var evaluations = 0
        log.debug({ evaluations += 1; return "password=hunter2" }())
        #expect(evaluations == 0)
        #expect(capture.messages.isEmpty)
    }

    @Test func enabledDebugEvaluatesMessageOnce() {
        let (log, _) = makeLog(enabled: true)
        var evaluations = 0
        log.debug({ evaluations += 1; return "ok" }())
        #expect(evaluations == 1)
    }

    @Test func setDebugEnabledTogglesGate() {
        let (log, capture) = makeLog(enabled: false)
        log.debug("a")
        #expect(capture.messages.isEmpty)
        log.setDebugEnabled(true)
        #expect(log.debugEnabled)
        log.debug("b")
        #expect(capture.messages.count == 1)
        log.setDebugEnabled(false)
        log.debug("c")
        #expect(capture.messages.count == 1)
    }

    @Test func levelsAreOrdered() {
        #expect(PluginDebugLog.Level.debug < .info)
        #expect(PluginDebugLog.Level.info < .warning)
        #expect(PluginDebugLog.Level.warning < .error)
    }

    @Test func logWithExplicitLevelRespectsGate() {
        let (log, capture) = makeLog(enabled: false)
        log.log(.debug, "d")
        log.log(.error, "e")
        #expect(capture.messages.map(\.level) == [.error])
    }
}