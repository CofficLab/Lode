import KernelCore
import LumiFactory
import XCTest
@testable import Lode

/// Guards the launch assembly budget: the median kernel-assembly time must stay
/// within tolerance of the committed baseline (scripts/perf/launch-baseline.json).
/// Wall-clock assembly time is load-sensitive, so locally a busy-spin CPU probe
/// detects scheduler contention: on a busy machine (probe median > 5ms; the probe
/// is sub-millisecond when idle) a lenient 5x tolerance applies, on a quiet machine
/// the strict 2x tolerance applies. On shared CI runners (GITHUB_ACTIONS=true) the
/// flat 5x tolerance always applies (observed ~3.2x slower than the baseline machine).
/// Regenerate the baseline deliberately via `LODE_PERF_MEASURE=1 xcodebuild test
/// -project Lode.xcodeproj -scheme Lode -only-testing:LodeTests/LaunchBudgetGateTests/testMeasureAssemblyBaseline`
/// on a quiet machine and commit the new value with justification in the commit message.
@MainActor
final class LaunchBudgetGateTests: LodeKernelTestCase {
    struct Baseline: Decodable {
        let assemblyMedianMs: Double
    }

    /// Probe medians above this indicate heavy scheduler contention; the probe
    /// is pure userspace CPU work that takes well under 1ms on an idle machine.
    private static let busyProbeThresholdMs = 5.0

    private var isCI: Bool {
        ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
    }

    private var baselineURL: URL {
        // 基线随测试 bundle 打包（project.yml / xcproj 的 resources）：
        // 宿主 App 运行时读源码树会触发跨卷文件访问授权并挂起测试。
        Bundle(for: Self.self).url(forResource: "launch-baseline", withExtension: "json")!
    }

    private func measureAssembly(samples: Int) async throws -> [Double] {
        // Warm-up: the first assembly pays one-time dyld/lazy-init costs that
        // are not part of the assembly work the budget guards.
        let warmUp = try await KernelAssembler.makeKernel(manifest: LodeHostManifest.make())
        try? await warmUp.stopAsync()
        var durations: [Double] = []
        for _ in 0..<samples {
            let start = CFAbsoluteTimeGetCurrent() * 1000
            let kernel = try await KernelAssembler.makeKernel(manifest: LodeHostManifest.make())
            durations.append(CFAbsoluteTimeGetCurrent() * 1000 - start)
            try? await kernel.stopAsync()
        }
        return durations
    }

    /// Busy-spin probe: pure userspace CPU work that inflates sharply under
    /// scheduler contention, used to detect whether the machine is busy.
    private func probe(samples: Int) -> [Double] {
        var durations: [Double] = []
        for _ in 0..<samples {
            let start = CFAbsoluteTimeGetCurrent() * 1000
            var x: Double = 1.000001
            for _ in 0..<300_000 {
                x = x * 1.000001 + 0.000001
            }
            withExtendedLifetime(x) {}
            durations.append(CFAbsoluteTimeGetCurrent() * 1000 - start)
        }
        return durations
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    func testAssemblyBudgetGate() async throws {
        let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: baselineURL))
        let durations = try await measureAssembly(samples: 5)
        let assemblyMedian = median(durations)
        if isCI {
            let limit = baseline.assemblyMedianMs * 5.0
            XCTAssertLessThanOrEqual(
                assemblyMedian, limit,
                "assembly median \(assemblyMedian)ms exceeds 5x baseline \(baseline.assemblyMedianMs)ms"
            )
        } else {
            let probeMedian = median(probe(samples: 5))
            let busy = probeMedian > Self.busyProbeThresholdMs
            let factor = busy ? 5.0 : 2.0
            let limit = baseline.assemblyMedianMs * factor
            XCTAssertLessThanOrEqual(
                assemblyMedian, limit,
                "assembly median \(assemblyMedian)ms exceeds \(factor)x baseline \(baseline.assemblyMedianMs)ms (probe \(probeMedian)ms, busy=\(busy))"
            )
        }
    }

    func testMeasureAssemblyBaseline() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["LODE_PERF_MEASURE"] != "1",
            "opt-in baseline measurement; set LODE_PERF_MEASURE=1"
        )
        let durations = try await measureAssembly(samples: 7)
        let assemblyMedian = median(durations)
        let probeMedian = median(probe(samples: 7))
        print("assembly samples(ms): \(durations.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        print("assembly median(ms): \(String(format: "%.1f", assemblyMedian))")
        print("probe median(ms): \(String(format: "%.3f", probeMedian))")
    }
}