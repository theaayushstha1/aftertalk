import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
final class RecordingViewModel {
    var isRecording = false
    /// True while iOS has us paused for a phone call / Siri / FaceTime / route
    /// change. `isRecording` stays true so the recording surface keeps the
    /// timer + mic plumbing intact, but the engine is paused and the UI shows
    /// an explicit "interrupted" badge so the user isn't fooled into thinking
    /// the meeting is still capturing audio.
    var isInterrupted: Bool = false
    /// Human-readable reason for the most recent interruption. Drives the
    /// banner copy in the recording surface (e.g. "Phone call paused this
    /// recording" vs "AirPods disconnected").
    var interruptionReason: String?
    var permissionDenied = false
    var transcript: String = ""
    /// Lines Moonshine has marked `isFinal=true`. Render with full ink. These
    /// are stable — the model has committed and won't revise them in the
    /// current session.
    var committedTranscript: String = ""
    /// The currently in-flight line (`isFinal=false`). Render dim/italic so
    /// the user perceives it as "tentative" — matches the grounding-gate
    /// pattern from CS Navigator: don't display as authoritative until the
    /// model has actually committed it via `LineCompleted`.
    var tentativeTranscript: String = ""
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
    /// VAD gate diagnostics — surfaced in `DebugOverlay` so the user can
    /// confirm on device that silence is actually being shed (forwardRatio
    /// should sit between 0.4 and 0.7 on conversational audio).
    var vadInSpeech: Bool = false
    var vadForwardRatio: Double = 0
    var vadTransitions: Int = 0

    private var committedLines: [String] = []
    private var activeLine: String = ""

    var onSessionEnded: (@MainActor (_ transcript: String, _ durationSeconds: Double, _ audioFileURL: URL?) -> Void)?

    /// Called when an interruption begins so the QA orchestrator (which owns
    /// TTS playback) can cancel any in-flight answer immediately, snapping
    /// audio focus to the caller. Wired from `AftertalkApp`. Optional —
    /// recording works without it; only Q&A surfaces install the hook.
    var onInterruptionCancelTTS: (@MainActor () async -> Void)?

    /// Optional perf-event hook fired when we successfully resume after an
    /// interruption. Wired from `AftertalkApp` so the SessionPerfSampler
    /// gets a `recording_resumed_after_interruption` row in its CSV without
    /// the VM having to know about the sampler type.
    var onPerfEvent: (@MainActor (_ label: String) async -> Void)?

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
    /// Captured at the moment iOS posts `.began`. The interruption observer
    /// flips this on so a subsequent `.ended` (with `.shouldResume`) knows
    /// whether to bring the engine back up. Reset on any clean start/stop.
    private var wasRecordingBeforeInterruption: Bool = false
    /// Wall-clock recording duration in seconds. Drives the recording-screen
    /// timer. Not derived from a stored timestamp because we want it to keep
    /// counting in 1s increments even if no audio frames have arrived yet.
    var elapsedSeconds: Double = 0
    private var elapsedTask: Task<Void, Never>?

    init() {
        let modelDir = ModelLocator.moonshineModelDirectory()
        let s = MoonshineStreamer(modelDirectory: modelDir)
        self.streamer = s
        self.pump = SamplePump(streamer: s)
        self.pump.onSamples = { [weak self] count, vad in
            Task { @MainActor in
                guard let self else { return }
                self.samplesIn += count
                self.vadInSpeech = vad.inSpeech
                self.vadForwardRatio = vad.forwardRatio
                self.vadTransitions = vad.transitions
            }
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

    /// Eagerly warm Moonshine's ONNX graphs so the *first* recording's TTFT
    /// drops from ~1.7s (cold compile) to <250ms. Safe to call repeatedly —
    /// `MoonshineStreamer.warm()` is idempotent. Wired from AftertalkApp's
    /// `.onAppear` so the cost amortizes during onboarding / first paint
    /// instead of stalling the user's first record press.
    func warmASR() async {
        do {
            try await streamer.warm()
        } catch {
            log.error("warm: \(String(describing: error), privacy: .public)")
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

            // Reset VAD state before mic samples start arriving so the
            // first chunk of this session can't be classified by leftover
            // in-speech / pre-roll state from the previous recording.
            pump.resetGate()
            try capture.start(pump: pump)
            startMonotonic = .now
            ttftMillis = nil
            transcript = ""
            committedTranscript = ""
            tentativeTranscript = ""
            committedLines.removeAll()
            activeLine = ""
            samplesIn = 0
            eventsIn = 0
            lastError = nil
            isRecording = true
            privacyMonitor?.isCapturingMeeting = true
            startElapsedTimer()
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
        await AudioSessionManager.shared.deactivate(force: true)
        // Moonshine fires a final LineCompleted from stream.stop() that still
        // has to traverse the dispatch queue + AsyncStream + main-actor consumer
        // before it lands in committedLines. 300ms gives that whole chain time
        // to drain so we don't snapshot a half-built transcript.
        try? await Task.sleep(for: .milliseconds(300))
        let captured = transcript
        // Do NOT cancel deltaTask/diagTask — they're long-lived consumers.
        isRecording = false
        isInterrupted = false
        interruptionReason = nil
        wasRecordingBeforeInterruption = false
        privacyMonitor?.isCapturingMeeting = false
        stopElapsedTimer()
        if !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSessionEnded?(captured, duration, audioURL)
        }
    }

    private func rollback() async {
        capture.stop()
        await streamer.stop()
        await AudioSessionManager.shared.deactivate(force: true)
        isRecording = false
        isInterrupted = false
        interruptionReason = nil
        wasRecordingBeforeInterruption = false
        privacyMonitor?.isCapturingMeeting = false
        stopElapsedTimer()
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedSeconds = 0
        let started = ContinuousClock.now
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.elapsedSeconds = Double(started.duration(to: .now).components.seconds) +
                    Double(started.duration(to: .now).components.attoseconds) / 1e18
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
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
        committedTranscript = committedLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        tentativeTranscript = activeLine.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ([committedTranscript, tentativeTranscript]
            .filter { !$0.isEmpty }
            .joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Interruption handling

    /// Called from `AudioInterruptionObserver.onInterruptionBegan`. Pauses
    /// the engine in place (does NOT deactivate the audio session — that
    /// deadlocks against attached nodes per CLAUDE.md) and cancels any TTS
    /// that's mid-utterance so the caller's audio takes over cleanly.
    func handleInterruptionBegan() async {
        wasRecordingBeforeInterruption = isRecording
        guard isRecording else { return }
        log.info("interruption began — pausing capture (wasRecording=\(self.wasRecordingBeforeInterruption, privacy: .public))")
        capture.pause()
        // Cancel any answer currently playing through TTS so we don't
        // half-talk over the caller. The orchestrator's cancel() drops
        // queued sentences + stops the player.
        await onInterruptionCancelTTS?()
        // Surface the partial WAV URL via a side log line. AVAudioFile
        // flushes per-buffer so frames captured up to this moment are
        // already on disk; the file header finalizes when stop() releases
        // the AVAudioFile reference at end-of-meeting.
        let partialURL = capture.partialRecordingURL()
        log.info("interruption: partial wav preserved=\(partialURL?.lastPathComponent ?? "<none>", privacy: .public)")
        isInterrupted = true
        interruptionReason = "Phone call or Siri paused this recording"
    }

    /// Called from `AudioInterruptionObserver.onInterruptionEnded`. If the
    /// OS asked us to resume + we were recording before, restart the engine
    /// in place and clear the interrupted badge. If `.shouldResume` is
    /// false, leave the recording in `.interrupted` state so the user can
    /// stop it manually rather than discovering a silent dead air gap.
    func handleInterruptionEnded(shouldResume: Bool) async {
        log.info("interruption ended shouldResume=\(shouldResume, privacy: .public) wasRecording=\(self.wasRecordingBeforeInterruption, privacy: .public)")
        guard wasRecordingBeforeInterruption else {
            isInterrupted = false
            interruptionReason = nil
            return
        }
        if shouldResume {
            let ok = capture.resume()
            if ok {
                isInterrupted = false
                interruptionReason = nil
                wasRecordingBeforeInterruption = false
                await onPerfEvent?("recording_resumed_after_interruption")
            } else {
                // Engine refused to come back — most likely the OS still
                // holds the route. Leave the interrupted state visible so
                // the user can intervene.
                lastError = "Could not resume recording after interruption"
                interruptionReason = "Recording could not resume — tap stop to save what was captured"
            }
        } else {
            // OS told us not to resume (e.g. user accepted a long call).
            // Keep the interrupted badge up so the user knows audio capture
            // is still cold even though the call ended.
            interruptionReason = "Recording was interrupted — tap stop to save what was captured"
        }
    }

    /// Called from `AudioInterruptionObserver.onRouteChanged` when the
    /// previously-selected output device disappeared (AirPods unplugged,
    /// BT dropout). Pause the engine and surface a banner. Resume happens
    /// either when the user taps stop + restarts, or via a future "resume"
    /// affordance on the recording surface.
    func handleRouteChanged(reason: String) async {
        guard isRecording else { return }
        log.info("route change: \(reason, privacy: .public) — pausing capture")
        capture.pause()
        wasRecordingBeforeInterruption = true
        isInterrupted = true
        interruptionReason = "Audio route changed — tap stop to save what was captured"
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
/// the streamer. Holds a strong ref to `MoonshineStreamer` so the streamer
/// outlives the audio tap closure, and an `EnergyVADGate` that strips
/// silence frames before they reach the encoder.
///
/// The pump runs on the audio render thread (single-writer) so the gate's
/// `nonisolated(unsafe)` mutable state is safe without extra locking. See
/// `EnergyVADGate.swift` for the architecture rationale.
private final class SamplePump: ASRSamplePump, @unchecked Sendable {
    private let streamer: MoonshineStreamer
    private let gate = EnergyVADGate()
    var onSamples: (@Sendable (Int, EnergyVADGate.Stats) -> Void)?
    init(streamer: MoonshineStreamer) { self.streamer = streamer }
    func append(samples: [Float], sampleRate: Int32) {
        let forwarded = gate.gate(samples: samples)
        if !forwarded.isEmpty {
            streamer.append(samples: forwarded, sampleRate: sampleRate)
        }
        // Always report gross input + gate stats so the UI can show input
        // arriving even during silence (otherwise the user thinks the mic
        // died) and so the debug overlay can verify the forward ratio.
        onSamples?(samples.count, gate.snapshot())
    }
    /// Wipe per-session gate state so a hangover in-speech flag, ring
    /// buffer, or stats counter from the previous recording can't bleed
    /// into the next one. Called from `RecordingViewModel.start`.
    func resetGate() { gate.reset() }
}
