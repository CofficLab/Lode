import FactoryDatabaseManager
import Foundation
import Testing

/// Guards the launch assembly budget: the median kernel-assembly time must stay
/// within 1.25x of the committed baseline (scripts/perf/launch-baseline.json).
/// Regenerate the baseline deliberately via `LODE_PERF_MEASURE=1 swift test
/// --package-path Packages/FactoryDatabaseManager --filter measureAssemblyBaseline`
/// and commit the new value with justification in the commit message.
@MainActor
struct LaunchBudgetGateTests {
    struct Baseline: Decodable {
        let assemblyMedianMs: Double
    }

    private var baselineURL: URL {
        // #filePath: <root>/Packages/FactoryDatabaseManager/Tests/FactoryDatabaseManagerTests/LaunchBudgetGateTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FactoryDatabaseManagerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // FactoryDatabaseManager
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // <root>
            .appendingPathComponent("scripts/perf/launch-baseline.json")
    }

    private func measureAssembly(samples: Int) throws -> [Double] {
        var durations: [Double] = []
        for _ in 0..<samples {
            let start = CFAbsoluteTimeGetCurrent() * 1000
            _ = try FactoryDatabaseManager.makeKernel()
            durations.append(CFAbsoluteTimeGetCurrent() * 1000 - start)
        }
        return durations
    }

    @Test("kernel assembly median stays within 1.25x of the committed baseline")
    func assemblyBudgetGate() throws {
        let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: baselineURL))
        let durations = try measureAssembly(samples: 5)
        let median = durations.sorted()[durations.count / 2]
        #expect(
            median <= baseline.assemblyMedianMs * 1.25,
            "assembly median \(median)ms exceeds 1.25x baseline \(baseline.assemblyMedianMs)ms"
        )
    }

    @Test("assembly baseline measurement (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["LODE_PERF_MEASURE"] == "1"))
    func measureAssemblyBaseline() throws {
        let durations = try measureAssembly(samples: 7)
        let median = durations.sorted()[durations.count / 2]
        print("assembly samples(ms): \(durations.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        print("assembly median(ms): \(String(format: "%.1f", median))")
    }
}