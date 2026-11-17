import Foundation
import os
import LumiLoggingKit

public enum LaunchPhase: String, Sendable, CaseIterable, Codable {
    case assembly = "launch.assembly"
    case firstWindow = "launch.firstWindow"
    case firstConnection = "launch.firstConnection"

    public var budgetMs: Double {
        switch self {
        case .assembly: return 300
        case .firstWindow: return 500
        // Includes real network round-trips; informational rather than a hard gate.
        case .firstConnection: return 3000
        }
    }
}

public struct LaunchRecord: Codable, Sendable, Equatable {
    public let phase: LaunchPhase
    public let durationMs: Double
    public let timestamp: Date
    public let appVersion: String

    public var isOverBudget: Bool { durationMs > phase.budgetMs }

    public init(phase: LaunchPhase, durationMs: Double, timestamp: Date, appVersion: String) {
        self.phase = phase
        self.durationMs = durationMs
        self.timestamp = timestamp
        self.appVersion = appVersion
    }
}

public struct LaunchSummary: Sendable, Equatable {
    public let phase: LaunchPhase
    public let count: Int
    public let medianMs: Double
    public let p95Ms: Double
    public let maxMs: Double
    public let overBudgetCount: Int

    public init(phase: LaunchPhase, count: Int, medianMs: Double, p95Ms: Double, maxMs: Double, overBudgetCount: Int) {
        self.phase = phase
        self.count = count
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.maxMs = maxMs
        self.overBudgetCount = overBudgetCount
    }
}

/// Tracks the three launch phases (kernel assembly, first window construction,
/// first database connection) with signposts and a persisted rolling history so
/// regressions are visible across launches, not just within one session.
@MainActor
public final class LaunchPerformance: SuperLog {
    public static let shared = LaunchPerformance()

    private let logger = Logger(subsystem: "com.coffic.lumi", category: "launch.perf")
    private let signpostLog = OSLog(subsystem: "com.coffic.lumi", category: "launch")
    private let defaults: UserDefaults
    private var history: [LaunchRecord] = []
    private var completedPhases: Set<LaunchPhase> = []
    private var activeSpans: [String: (phase: LaunchPhase, start: TimeInterval, signpostID: OSSignpostID)] = [:]

    public static let historyKey = "DatabaseManager.launchHistory"
    public static let maxHistory = 50

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.historyKey),
           let decoded = try? JSONDecoder().decode([LaunchRecord].self, from: data) {
            history = decoded
        }
    }

    /// Begins a span. Each phase is recorded once per process; later calls
    /// (e.g. reconnects after the first connection) return nil.
    @discardableResult
    public func begin(_ phase: LaunchPhase) -> String? {
        guard !completedPhases.contains(phase) else { return nil }
        let token = UUID().uuidString
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "Launch", signpostID: signpostID, "%{public}s", phase.rawValue)
        activeSpans[token] = (phase: phase, start: CFAbsoluteTimeGetCurrent() * 1000, signpostID: signpostID)
        return token
    }

    public func end(_ token: String, appVersion: String = LaunchPerformance.currentAppVersion) {
        guard let span = activeSpans.removeValue(forKey: token) else { return }
        let duration = CFAbsoluteTimeGetCurrent() * 1000 - span.start
        os_signpost(.end, log: signpostLog, name: "Launch", signpostID: span.signpostID, "%{public}s %.1fms", span.phase.rawValue, duration)
        completedPhases.insert(span.phase)

        let record = LaunchRecord(phase: span.phase, durationMs: duration, timestamp: Date(), appVersion: appVersion)
        history.append(record)
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
        persist()

        if record.isOverBudget {
            logger.warning("\(self.t)🐢 launch phase \(span.phase.rawValue) over budget: \(String(format: "%.1f", duration))ms (budget \(String(format: "%.0f", span.phase.budgetMs))ms)")
        } else {
            logger.info("\(self.t)🚀 \(span.phase.rawValue): \(String(format: "%.1f", duration))ms")
        }
    }

    public func cancel(_ token: String) {
        guard let span = activeSpans.removeValue(forKey: token) else { return }
        os_signpost(.end, log: signpostLog, name: "Launch", signpostID: span.signpostID, "cancelled")
    }

    /// Measures a synchronous throwing block (kernel assembly) once per phase.
    public func measure(_ phase: LaunchPhase, appVersion: String = LaunchPerformance.currentAppVersion, _ block: () throws -> Void) rethrows {
        guard let token = begin(phase) else {
            try block()
            return
        }
        do {
            try block()
            end(token, appVersion: appVersion)
        } catch {
            cancel(token)
            throw error
        }
    }

    public var lastRecord: LaunchRecord? { history.last }

    public func records(for phase: LaunchPhase) -> [LaunchRecord] {
        history.filter { $0.phase == phase }
    }

    public func summary(for phase: LaunchPhase) -> LaunchSummary? {
        let durations = records(for: phase).map(\.durationMs).sorted()
        guard !durations.isEmpty else { return nil }
        let count = durations.count
        return LaunchSummary(
            phase: phase,
            count: count,
            medianMs: durations[count / 2],
            p95Ms: durations[min(count - 1, Int(Double(count) * 0.95))],
            maxMs: durations[count - 1],
            overBudgetCount: durations.filter { $0 > phase.budgetMs }.count
        )
    }

    public func report() -> String {
        var lines = ["=== Launch Performance ==="]
        for phase in LaunchPhase.allCases {
            guard let s = summary(for: phase) else {
                lines.append("\(phase.rawValue): (no data)")
                continue
            }
            lines.append(String(format: "%-22@ n=%2d median=%7.1fms p95=%7.1fms max=%7.1fms over-budget=%d",
                                s.phase.rawValue, s.count, s.medianMs, s.p95Ms, s.maxMs, s.overBudgetCount))
        }
        return lines.joined(separator: "\n")
    }

    public func clear() {
        history.removeAll()
        completedPhases.removeAll()
        defaults.removeObject(forKey: Self.historyKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }

    public static var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}