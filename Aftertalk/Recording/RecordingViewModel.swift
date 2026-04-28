import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
final class RecordingViewModel {
    var isRecording = false
    var permissionDenied = false
    var transcript: String = ""
    var ttftMillis: Double?
    var samplesIn: Int = 0
    var eventsIn: Int = 0
    var lastError: String?
    var micPermission: String = "?"
    var asrActive: Bool = false
    var asrAddCalls: Int = 0
    var asrAddErrors: Int = 0
    var asrStarts: Int = 0
    var asrStops: Int = 0

    private var committedLines: [String] = []
    private var activeLine: String = ""

    var onSessionEnded: (@MainActor (_ transcript: String, _ durationSeconds: Double, _ audioFileURL: URL?) -> Void)?

    /// Optional: when set, the VM toggles `isCapturingMeeting` so the
    /// `NWPathMonitor`-based privacy gate can fire `.violation` if any
    /// interface is up while recording. Wired from RootView so the gate is
    /// auditable rather than dead code.
    var privacyMonitor: PrivacyMonitor?

    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "VM")
    private let capture = AudioCaptureService()
    private let streamer: MoonshineStreamer
    private let pump: SamplePump
    private var deltaTask: Task<Void, Never>?
    private var diagTask: Task<Void, Never>?
    private var startMonotonic: ContinuousClock.Instant?

    init() {
        let modelDir = ModelLocator.moonshineModelDirectory()
        let s = MoonshineStreamer(modelDirectory: modelDir)
        self.streamer = s
        self.pump = SamplePump(streamer: s)
        self.pump.onSamples = { [weak self] count in
            Task { @MainActor in self?.samplesIn += count }
        }
        // AsyncStream is single-iteration. Start the consumers ONCE so they
        // survive across recording sessions; otherwise the second session's
        // newly-spawned Task can't iterate the same AsyncStream and silently
        // misses every event/diagnostic yield.
        let deltas = s.deltas()
        self.deltaTask = Task { @MainActor [weak self] in
            for await delta in deltas {
                self?.apply(delta: delta)
            }
        }
        let diags = s.diagnostics()
        self.diagTask = Task { @MainActor [weak self] in
            for await d in diags {
                self?.applyDiag(d)
            }
        }
    }

    func toggle() async {
        if isRecording {
            await stop()
        } else {
            await start()
        }
    }

    private func start() async {
        let granted = await Self.requestMicPermission()
        micPermission = granted ? "granted" : "denied"
        guard granted else {
            permissionDenied = true
            lastError = "mic permission denied"
            return
        }
        do {
            try await AudioSessionManager.shared.configureForRecording()
            try await streamer.start()

            try capture.start(pump: pump)
            startMonotonic = .now
            ttftMillis = nil
            transcript = ""
            committedLines.removeAll()
            activeLine = ""
            samplesIn = 0
            eventsIn = 0
            lastError = nil
            isRecording = true
            privacyMonitor?.isCapturingMeeting = true
        } catch let err as AudioCaptureError {
            log.error("capture: \(String(describing: err), privacy: .public)")
            lastError = "capture: \(err)"
            await rollback()
        } catch let err as MoonshineError {
            log.error("moonshine: \(String(describing: err), privacy: .public)")
            lastError = "moonshine: \(err)"
            await rollback()
        } catch let err as AudioSessionError {
            log.error("session: \(String(describing: err), privacy: .public)")
            lastError = "session: \(err)"
            await rollback()
        } catch {
            log.error("start: \(String(describing: error), privacy: .public)")
            lastError = "start: \(error)"
            await rollback()
        }
    }

    private func stop() async {
        let endedAt = ContinuousClock.now
        let duration = startMonotonic.map { Double($0.duration(to: endedAt).aftertalkMillis) / 1000.0 } ?? 0
        capture.stop()
        let audioURL = capture.lastRecordingURL
        await streamer.stop()
        await AudioSessionManager.shared.deactivate()
        // Moonshine fires a final LineCompleted from stream.stop() that still
        // has to traverse the dispatch queue + AsyncStream + main-actor consumer
        // before it lands in committedLines. 300ms gives that whole chain time
        // to drain so we don't snapshot a half-built transcript.
        try? await Task.sleep(for: .milliseconds(300))
        let captured = transcript
        // Do NOT cancel deltaTask/diagTask — they're long-lived consumers.
        isRecording = false
        privacyMonitor?.isCapturingMeeting = false
        if !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSessionEnded?(captured, duration, audioURL)
        }
    }

    private func rollback() async {
        capture.stop()
        await streamer.stop()
        await AudioSessionManager.shared.deactivate()
        isRecording = false
        privacyMonitor?.isCapturingMeeting = false
    }

    private static func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }

    // Ensure committed lines end with a sentence terminator so the downstream
    // summary windower (NLTokenizer-based) can split the transcript into sentences.
    private func terminate(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        if last == "." || last == "?" || last == "!" { return trimmed }
        return trimmed + "."
    }

    private func apply(delta: TranscriptDelta) {
        eventsIn += 1
        if ttftMillis == nil, let start = startMonotonic, !delta.text.isEmpty {
            ttftMillis = start.millis(to: .now)
        }
        // Moonshine deltas are line-scoped: each event carries one sentence.
        // Accumulate completed lines so the full meeting transcript is preserved.
        if delta.isFinal {
            let line = terminate(delta.text)
            if !line.isEmpty { committedLines.append(line) }
            activeLine = ""
        } else {
            activeLine = delta.text
        }
        transcript = ([committedLines.joined(separator: " "), activeLine]
            .filter { !$0.isEmpty }
            .joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyDiag(_ d: ASRDiagnostics) {
        asrActive = d.isActive
        asrAddCalls = d.addAudioCalls
        asrAddErrors = d.addAudioErrors
        asrStarts = d.startCalls
        asrStops = d.stopCalls
        if let err = d.lastAddAudioError, lastError == nil {
            lastError = "asr: \(err)"
        }
    }
}

/// Thin Sendable bridge between AVAudioEngine's tap callback (off-main) and
/// the streamer. Holding a strong ref to MoonshineStreamer keeps it alive
/// while the pump is captured in the audio tap closure.
private final class SamplePump: ASRSamplePump, @unchecked Sendable {
    private let streamer: MoonshineStreamer
    var onSamples: (@Sendable (Int) -> Void)?
    init(streamer: MoonshineStreamer) { self.streamer = streamer }
    func append(samples: [Float], sampleRate: Int32) {
        streamer.append(samples: samples, sampleRate: sampleRate)
        onSamples?(samples.count)
    }
}
