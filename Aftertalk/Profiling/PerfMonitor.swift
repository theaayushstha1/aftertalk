import Foundation
import os

actor PerfMonitor {
    static let shared = PerfMonitor()

    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Perf")

    func record(metric: String, value: Double, unit: String = "ms") {
        log.info("\(metric, privacy: .public)=\(value, privacy: .public)\(unit, privacy: .public)")
    }
}

extension ContinuousClock.Instant {
    func millis(to other: ContinuousClock.Instant) -> Double {
        let dur = self.duration(to: other)
        let comps = dur.components
        return Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
    }
}
