import Foundation
import Testing
@testable import DatabaseManagerPlugin

@MainActor
struct LaunchPerformanceTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "LaunchPerformanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("measure records a duration for the phase")
    func measureRecordsDuration() {
        let perf = LaunchPerformance(defaults: freshDefaults())
        perf.measure(.assembly) { Thread.sleep(forTimeInterval: 0.01) }
        let record = perf.lastRecord
        #expect(record?.phase == .assembly)
        #expect((record?.durationMs ?? 0) >= 5)
        #expect(perf.records(for: .assembly).count == 1)
    }

    @Test("each phase is recorded only once per process")
    func firstOnlySemantics() {
        let perf = LaunchPerformance(defaults: freshDefaults())
        let first = perf.begin(.firstConnection)
        #expect(first != nil)
        perf.end(first!)
        #expect(perf.begin(.firstConnection) == nil)
        #expect(perf.records(for: .firstConnection).count == 1)
    }

    @Test("cancel leaves the phase available for a later attempt")
    func cancelDoesNotCompletePhase() {
        let perf = LaunchPerformance(defaults: freshDefaults())
        let token = perf.begin(.assembly)!
        perf.cancel(token)
        #expect(perf.records(for: .assembly).isEmpty)
        #expect(perf.begin(.assembly) != nil)
    }

    @Test("measure rethrows and keeps the phase retryable")
    func measureRethrows() {
        struct Boom: Error {}
        let perf = LaunchPerformance(defaults: freshDefaults())
        #expect(throws: Boom.self) {
            try perf.measure(.assembly) { throw Boom() }
        }
        #expect(perf.records(for: .assembly).isEmpty)
        #expect(perf.begin(.assembly) != nil)
    }

    @Test("summary computes median, p95, max and over-budget count")
    func summaryStatistics() throws {
        let defaults = freshDefaults()
        let records = [100.0, 400.0, 200.0, 350.0, 50.0].map {
            LaunchRecord(phase: .assembly, durationMs: $0, timestamp: Date(), appVersion: "test")
        }
        defaults.set(try JSONEncoder().encode(records), forKey: LaunchPerformance.historyKey)
        let perf = LaunchPerformance(defaults: defaults)
        let summary = try #require(perf.summary(for: .assembly))
        #expect(summary.count == 5)
        #expect(summary.medianMs == 200)
        #expect(summary.p95Ms == 400)
        #expect(summary.maxMs == 400)
        #expect(summary.overBudgetCount == 2)
    }

    @Test("history persists across instances")
    func persistenceRoundTrip() {
        let defaults = freshDefaults()
        let first = LaunchPerformance(defaults: defaults)
        first.measure(.firstWindow) {}
        let second = LaunchPerformance(defaults: defaults)
        #expect(second.records(for: .firstWindow).count == 1)
        #expect(second.lastRecord?.phase == .firstWindow)
    }

    @Test("history is capped at maxHistory entries")
    func historyCap() throws {
        let defaults = freshDefaults()
        let records = (0..<LaunchPerformance.maxHistory).map {
            LaunchRecord(phase: .assembly, durationMs: Double($0), timestamp: Date(), appVersion: "test")
        }
        defaults.set(try JSONEncoder().encode(records), forKey: LaunchPerformance.historyKey)
        let perf = LaunchPerformance(defaults: defaults)
        perf.measure(.firstWindow) {}
        #expect(perf.records(for: .assembly).count == LaunchPerformance.maxHistory - 1)
        #expect(perf.records(for: .firstWindow).count == 1)
    }

    @Test("report lists every phase")
    func reportCoversAllPhases() {
        let perf = LaunchPerformance(defaults: freshDefaults())
        let report = perf.report()
        for phase in LaunchPhase.allCases {
            #expect(report.contains(phase.rawValue))
        }
    }

    @Test("clear empties memory and persistence")
    func clearRemovesEverything() {
        let defaults = freshDefaults()
        let perf = LaunchPerformance(defaults: defaults)
        perf.measure(.assembly) {}
        perf.clear()
        #expect(perf.lastRecord == nil)
        #expect(LaunchPerformance(defaults: defaults).lastRecord == nil)
        #expect(perf.begin(.assembly) != nil)
    }

    @Test("record Codable round-trip preserves fields")
    func recordCodableRoundTrip() throws {
        let record = LaunchRecord(phase: .firstConnection, durationMs: 123.5, timestamp: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "1.2.3")
        let decoded = try JSONDecoder().decode(LaunchRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }

    @Test("budgets are positive and ordered by phase scope")
    func budgetValues() {
        for phase in LaunchPhase.allCases {
            #expect(phase.budgetMs > 0)
        }
        #expect(LaunchPhase.firstConnection.budgetMs > LaunchPhase.assembly.budgetMs)
    }
}

#if DEBUG
struct MainThreadStallMonitorTests {
    @Test("stall classification uses a strict threshold")
    func stallClassification() {
        #expect(MainThreadStallMonitor.isStall(elapsedMs: 300, thresholdMs: 250))
        #expect(!MainThreadStallMonitor.isStall(elapsedMs: 250, thresholdMs: 250))
        #expect(!MainThreadStallMonitor.isStall(elapsedMs: 10, thresholdMs: 250))
    }

    @Test("start and stop are idempotent")
    func startStopLifecycle() {
        let monitor = MainThreadStallMonitor(thresholdMs: 60_000, probeIntervalMs: 50)
        #expect(!monitor.isRunning)
        monitor.start()
        #expect(monitor.isRunning)
        monitor.start()
        #expect(monitor.isRunning)
        monitor.stop()
        #expect(!monitor.isRunning)
        monitor.stop()
        #expect(!monitor.isRunning)
    }

    @Test("initializer clamps non-positive intervals")
    func initializerClamps() {
        let monitor = MainThreadStallMonitor(thresholdMs: 0, probeIntervalMs: -5)
        #expect(monitor.thresholdMs == 1)
        #expect(monitor.probeIntervalMs == 1)
    }
}
#endif