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

    var onSessionEnded: (@MainActor (_ transcript: String, _ durationSeconds: Double) -> Void)?

    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "VM")
    private let capture = AudioCaptureService()
    private let streamer: MoonshineStreamer
    private let pump: SamplePump
    private var deltaTask: Task<Void, Never>?
    private var diagTask: Task<Void, Never>?
    private var startMonotonic: ContinuousClock.Instant?

    init() {
        let modelDir = ModelLocator.moonshineTinyDirectory()
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
            samplesIn = 0
            eventsIn = 0
            lastError = nil
            isRecording = true
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
        await streamer.stop()
        await AudioSessionManager.shared.deactivate()
        // Brief yield so any final LineCompleted delta queued on the AsyncStream
        // has a chance to apply before we hand the transcript to the pipeline.
        try? await Task.sleep(for: .milliseconds(150))
        let captured = transcript
        // Do NOT cancel deltaTask/diagTask — they're long-lived consumers.
        isRecording = false
        if !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSessionEnded?(captured, duration)
        }
    }

    private func rollback() async {
        capture.stop()
        await streamer.stop()
        await AudioSessionManager.shared.deactivate()
        isRecording = false
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

    private func apply(delta: TranscriptDelta) {
        eventsIn += 1
        if ttftMillis == nil, let start = startMonotonic, !delta.text.isEmpty {
            ttftMillis = start.millis(to: .now)
        }
        transcript = delta.text
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
