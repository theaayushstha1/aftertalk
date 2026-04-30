import Foundation
import UIKit
import Darwin
import Darwin.Mach
import os

/// In-session perf sampler. Polls memory / CPU / thermal / battery once per
/// second while a meeting + Q&A session is active and writes a per-row CSV
/// to `~/Library/Caches/com.theaayushstha.aftertalk/perf/<sessionId>.csv`.
///
/// Why not MetricKit alone: `MXMetricManager` aggregates per-day and arrives
/// on the *next* app launch via `didReceive payloads:`. For a take-home demo
/// we want same-session numbers we can chart immediately, so we sample in
/// process and let MetricKit be the cross-session sanity check.
///
/// The sampler is `actor`-isolated; the timer runs as an unstructured `Task`
/// because we want continuous 1 Hz ticks even if the main thread is busy
/// rendering Foundation Models snapshots.
actor SessionPerfSampler {
    struct Sample {
        let elapsedSeconds: Double
        let memoryMB: Double
        let cpuPercent: Double
        /// `ProcessInfo.thermalState.rawValue`: nominal=0, fair=1, serious=2, critical=3.
        let thermalState: Int
        /// `UIDevice.current.batteryLevel` * 100. -100 when monitoring disabled.
        let batteryPercent: Double
        let event: String?
    }

    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Perf")
    private let sessionId: String
    private let outputURL: URL
    private let started: Date
    private var samples: [Sample] = []
    private var ticker: Task<Void, Never>?
    private var stopped = false

    init(sessionId: String = ISO8601DateFormatter.yyyymmddhhmmss(Date())) {
        self.sessionId = sessionId
        self.started = Date()
        // Documents (not Caches) so the user can pull the CSV via Files app
        // → AirDrop / iCloud Drive without needing a debug device USB session.
        // The Info.plist sets `UIFileSharingEnabled=YES` for the Files app
        // browse path.
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("perf", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: base.path
        )
        self.outputURL = base.appendingPathComponent("\(sessionId).csv")
    }

    /// Begin sampling. Idempotent; calling twice is a no-op.
    func start(eventLabel: String = "session_start") async {
        guard ticker == nil, !stopped else { return }
        // Battery monitoring is opt-in. Flip it on here so `batteryLevel`
        // returns a real value, not -1.0. Caller doesn't need to undo this —
        // the OS resets it when the app exits.
        await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled = true }
        await record(event: eventLabel)
        ticker = Task { [weak self] in
            while let self, await !self.isStopped() {
                await self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        log.info("perf: session \(self.sessionId, privacy: .public) sampling started → \(self.outputURL.lastPathComponent, privacy: .public)")
    }

    /// Stop sampling and flush CSV. Returns the file URL.
    @discardableResult
    func stop(eventLabel: String = "session_end") async -> URL {
        guard !stopped else { return outputURL }
        await record(event: eventLabel)
        stopped = true
        ticker?.cancel()
        ticker = nil
        flushCSV()
        log.info("perf: session \(self.sessionId, privacy: .public) sampling stopped — \(self.samples.count, privacy: .public) rows")
        return outputURL
    }

    /// Record an event marker without changing the sampling cadence. Use to
    /// annotate timeline boundaries (e.g. "qa_question_3", "tts_first_word")
    /// so the chart can mark them.
    func record(event: String) async {
        let battery = await Self.batteryLevelPercent()
        let row = Self.snapshot(
            elapsedSeconds: Date().timeIntervalSince(started),
            batteryPercent: battery,
            event: event
        )
        samples.append(row)
    }

    private func isStopped() -> Bool { stopped }

    private func tick() async {
        let battery = await Self.batteryLevelPercent()
        let row = Self.snapshot(
            elapsedSeconds: Date().timeIntervalSince(started),
            batteryPercent: battery,
            event: nil
        )
        samples.append(row)
        // Flush every 10 ticks (~10 s) so a crash mid-session doesn't drop
        // every sample we collected. Cheap — even a 60-min session is only
        // ~3,600 rows × ~60 bytes each = 220 KB to rewrite.
        if samples.count % 10 == 0 {
            flushCSV()
        }
    }

    /// Snapshot the file URL so callers can present a share sheet.
    func currentOutputURL() -> URL { outputURL }

    private static func snapshot(
        elapsedSeconds: Double,
        batteryPercent: Double,
        event: String?
    ) -> Sample {
        Sample(
            elapsedSeconds: elapsedSeconds,
            memoryMB: residentMemoryMB(),
            cpuPercent: processCPUPercent(),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            batteryPercent: batteryPercent,
            event: event
        )
    }

    private func flushCSV() {
        var out = "elapsed_s,memory_mb,cpu_pct,thermal,battery_pct,event\n"
        for s in samples {
            let event = s.event?.replacingOccurrences(of: ",", with: ";") ?? ""
            out.append(String(
                format: "%.2f,%.1f,%.1f,%d,%.1f,%@\n",
                s.elapsedSeconds, s.memoryMB, s.cpuPercent, s.thermalState, s.batteryPercent, event
            ))
        }
        do {
            try out.write(to: outputURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: outputURL.path
            )
        } catch {
            log.error("perf: CSV write failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - System probes

    /// Resident set size for the current process, in MB. Uses
    /// `mach_task_basic_info.resident_size` — the closest equivalent to what
    /// Xcode's memory gauge displays.
    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    /// Aggregate CPU usage across all threads in the current task as a percent
    /// of one core. >100% means we're using more than one core, which is fine
    /// — what matters for thermal/battery is the integral over time.
    private static func processCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let list = threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        }
        var totalCPU: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { rebound in
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), rebound, &infoCount)
                }
            }
            guard kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 else { continue }
            totalCPU += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return totalCPU
    }

    /// `UIDevice.batteryLevel` is `@MainActor`-isolated. Our sampling tick
    /// runs on this actor (not main), so we hop once per second. The hop is
    /// cheap (~µs); the alternative is caching via `batteryLevelDidChange`
    /// notification, which adds an observer + race window for one float.
    @MainActor
    private static func batteryLevelPercent() -> Double {
        let lvl = UIDevice.current.batteryLevel
        return lvl < 0 ? -100 : Double(lvl * 100)
    }
}

private extension ISO8601DateFormatter {
    static func yyyymmddhhmmss(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
