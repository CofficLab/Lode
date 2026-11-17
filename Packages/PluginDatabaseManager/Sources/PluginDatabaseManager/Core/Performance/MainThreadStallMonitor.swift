#if DEBUG
import Foundation
import os

/// DEBUG-only watchdog: a background thread periodically probes the main queue
/// and logs any round-trip that exceeds the stall threshold, surfacing main-thread
/// hangs during development without shipping overhead in release builds.
public final class MainThreadStallMonitor: @unchecked Sendable {
    public static let shared = MainThreadStallMonitor()

    private let logger = Logger(subsystem: "com.coffic.lumi", category: "main.stall")
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?

    public let thresholdMs: Double
    public let probeIntervalMs: Double

    public init(thresholdMs: Double = 250, probeIntervalMs: Double = 100) {
        self.thresholdMs = max(1, thresholdMs)
        self.probeIntervalMs = max(1, probeIntervalMs)
    }

    public static func isStall(elapsedMs: Double, thresholdMs: Double) -> Bool {
        elapsedMs > thresholdMs
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        let threshold = thresholdMs
        let interval = probeIntervalMs
        let logger = logger
        let worker = Thread { [weak self] in
            while true {
                guard let self else { return }
                self.lock.lock()
                let alive = self.running
                self.lock.unlock()
                guard alive else { return }

                let semaphore = DispatchSemaphore(value: 0)
                let start = CFAbsoluteTimeGetCurrent() * 1000
                DispatchQueue.main.async { semaphore.signal() }
                let timedOut = semaphore.wait(timeout: .now() + threshold / 1000) == .timedOut
                if timedOut {
                    // Main queue is blocked; wait for the actual ack to measure the full stall.
                    semaphore.wait()
                    let elapsed = CFAbsoluteTimeGetCurrent() * 1000 - start
                    if Self.isStall(elapsedMs: elapsed, thresholdMs: threshold) {
                        logger.warning("⚠️ main thread stalled \(String(format: "%.0f", elapsed))ms (threshold \(String(format: "%.0f", threshold))ms)")
                    }
                }
                Thread.sleep(forTimeInterval: interval / 1000)
            }
        }
        worker.name = "com.coffic.lumi.main-stall-monitor"
        worker.qualityOfService = .utility
        thread = worker
        worker.start()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        running = false
        thread = nil
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}
#endif