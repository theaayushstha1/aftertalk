import AVFoundation
import Foundation
import os

enum QuestionASRError: Error, CustomStringConvertible {
    case permissionDenied
    case captureFailed(any Error)
    case asrFailed(any Error)
    case sessionFailed(any Error)

    var description: String {
        switch self {
        case .permissionDenied: return "Microphone permission denied."
        case .captureFailed(let e): return "Audio capture failed: \(e)"
        case .asrFailed(let e): return "ASR failed: \(e)"
        case .sessionFailed(let e): return "Audio session failed: \(e)"
        }
    }
}

/// Records a short voice question and returns the final transcript on release.
///
/// Owns its own MoonshineStreamer so it doesn't conflict with the meeting
/// recorder's instance. Audio session runs in `.playAndRecord` + `.voiceChat`
/// for the entire Q&A turn so Kokoro can speak the answer back through the
/// same active session — switching to `.record` would silently disable the
/// output unit and `engine.start()` on TTSWorker would fail with -10851
/// ("Format not supported", 0 Hz output rate). Session stays live across
/// listen → think → speak; deactivation happens when ChatThreadView
/// disappears.
@MainActor
final class QuestionASR {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "QuestionASR")
    private let streamer: MoonshineStreamer
    private let pump: Pump
    private let capture = AudioCaptureService()
    private var deltaTask: Task<Void, Never>?

    private(set) var liveTranscript: String = ""
    private var committedLines: [String] = []
    private var activeLine: String = ""
    /// Set true at the start of `stop()`; flipped back to false the moment
    /// the next final `LineCompleted` arrives. The continuation in
    /// `awaitFinalDelta` resumes off this flag so we don't gate on a fixed
    /// sleep — short utterances can finalize in 80 ms, long ones in 700 ms.
    private var awaitingFinal: Bool = false
    private var finalContinuation: CheckedContinuation<Void, Never>?

    init() {
        let dir = ModelLocator.moonshineModelDirectory()
        let s = MoonshineStreamer(modelDirectory: dir)
        self.streamer = s
        self.pump = Pump(streamer: s)
        let deltas = s.deltas()
        self.deltaTask = Task { @MainActor [weak self] in
            for await delta in deltas {
                self?.apply(delta: delta)
            }
        }
    }

    /// Loads the Moonshine model graph so the first hold-to-ask doesn't lose
    /// the user's opening words to a ~400ms cold start. Safe to call multiple
    /// times — Moonshine's `warm()` is idempotent.
    func prewarm() async {
        do { try await streamer.warm() }
        catch { log.error("prewarm failed: \(String(describing: error), privacy: .public)") }
    }

    func start() async throws(QuestionASRError) {
        let granted = await Self.requestMicPermission()
        guard granted else { throw .permissionDenied }
        committedLines.removeAll()
        activeLine = ""
        liveTranscript = ""
        awaitingFinal = false
        // Reset the gate's per-question state (pre-roll ring, in-speech
        // flag, stats) so a hangover from the previous turn can't gate a
        // syllable of the new one.
        pump.resetGate()
        do {
            // Use the clean (`.measurement`-mode) path while the user is
            // talking — Apple's voice-processing IO unit (engaged by
            // `.voiceChat`) measurably degrades Moonshine accuracy on
            // free-form questions. The orchestrator flips the session back
            // to voiceChat before Kokoro speaks the answer.
            try await AudioSessionManager.shared.configureForVoiceQuestion()
        } catch {
            throw .sessionFailed(error)
        }
        do {
            try await streamer.start()
        } catch {
            throw .asrFailed(error)
        }
        do {
            try capture.start(pump: pump)
        } catch {
            await streamer.stop()
            throw .captureFailed(error)
        }
    }

    /// Stops capture, pads the encoder with trailing silence, then waits for
    /// the model's final `LineCompleted` event before returning the
    /// transcript. Leaves the audio session active in `.playAndRecord` +
    /// `.voiceChat` so Kokoro can play the answer back through the same
    /// engine. The session is torn down by `ChatThreadView`'s lifecycle when
    /// the user navigates away.
    ///
    /// Why this is more than a `sleep(300)`:
    ///
    /// Moonshine streaming endpoints — i.e. emits `LineCompleted` — when its
    /// VAD sees a trailing silence bookend after a chunk of speech. With
    /// hold-to-talk Q&A, the user releases the button right after the last
    /// word, so the model never sees that silence and the final 1–3 words
    /// of a short question can be left as a tentative `LineTextChanged`
    /// that we throw away on `streamer.stop()`. Two fixes:
    ///
    ///   1. Push ~600 ms of zero-padded silence into the encoder *before*
    ///      stopping the stream. That's the bookend the model needs.
    ///   2. Wait for the actual final delta to arrive via a continuation
    ///      (with a 1200 ms ceiling so a botched encoder pass can't hang
    ///      the UI). Beats the old fixed `sleep(300)` which was both too
    ///      long for fast answers and too short for slow ones.
    func stop() async -> String {
        capture.stop()
        // Tail-pad the encoder. 600 ms is enough for Moonshine streaming
        // to register an endpoint and emit the final line; 16 kHz mono
        // matches what the meeting capture pipeline already converts to.
        let trailingMs = 600
        let sampleRate: Int32 = 16_000
        let count = Int(sampleRate) * trailingMs / 1000
        let silence = [Float](repeating: 0, count: count)
        awaitingFinal = !activeLine.isEmpty || liveTranscript.isEmpty
        // Bypass the VAD gate — feeding silence through a gate whose job
        // is "drop silence" is a no-op. Push directly to Moonshine so the
        // encoder definitely sees the bookend.
        pump.appendBypassingGate(samples: silence, sampleRate: sampleRate)
        // Wait for the next final `LineCompleted` to arrive (resumed in
        // `apply(delta:)`) or 1200 ms — whichever first. We only block if
        // there's actually a tentative line to commit; if the user
        // released after a confirmed final, skip the wait entirely.
        var didTimeOut = false
        if awaitingFinal {
            didTimeOut = await awaitFinalDelta(timeoutMs: 1200)
        }
        await streamer.stop()
        // After streamer.stop() Moonshine still flushes one synchronous
        // event through the listener queue. Default drain is 100 ms because
        // awaitFinalDelta has already absorbed the encoder latency. If the
        // wait timed out, though, `streamer.stop()` is now the *only*
        // remaining finalization path — Moonshine fires its terminal
        // LineCompleted from inside `Stream.stop()` and that event still
        // has to traverse the listener queue and main-actor consumer.
        // Bump the drain to 400 ms in that case so the late finalize lands
        // before we snapshot the transcript.
        let drainMs = didTimeOut ? 400 : 100
        try? await Task.sleep(for: .milliseconds(drainMs))
        return liveTranscript
    }

    /// Suspends the caller until the next final `LineCompleted` arrives or
    /// the timeout fires, whichever first. The continuation is parked in
    /// `finalContinuation`; the delta consumer resumes it from
    /// `apply(delta:)`. The timeout is racing on a detached `Task.sleep`
    /// so we never end up suspended past the ceiling even if the model
    /// silently never emits. Returns `true` if we timed out, so the
    /// caller can decide whether to extend the post-stop drain.
    private func awaitFinalDelta(timeoutMs: Int) async -> Bool {
        var timedOut = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.finalContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                guard let self else { return }
                if let pending = self.finalContinuation {
                    self.finalContinuation = nil
                    self.awaitingFinal = false
                    timedOut = true
                    self.log.info("awaitFinalDelta: timed out after \(timeoutMs, privacy: .public) ms — extending drain via streamer.stop()")
                    pending.resume()
                }
            }
        }
        return timedOut
    }

    private func apply(delta: TranscriptDelta) {
        if delta.isFinal {
            let line = delta.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { committedLines.append(line) }
            activeLine = ""
            // Wake `awaitFinalDelta` if `stop()` is currently parked
            // waiting for this exact event. The timeout-task in that
            // helper guards against double-resume by clearing the
            // continuation slot before we reach this branch.
            if awaitingFinal, let pending = finalContinuation {
                finalContinuation = nil
                awaitingFinal = false
                pending.resume()
            }
        } else {
            activeLine = delta.text
        }
        liveTranscript = ([committedLines.joined(separator: " "), activeLine]
            .filter { !$0.isEmpty }
            .joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Bridge from the audio capture tap into Moonshine. Uses the same
    /// `EnergyVADGate` as the meeting recorder but tuned for short
    /// hold-to-talk Q&A: longer hold-tail (500 ms vs 300 ms) so a soft
    /// trailing consonant on a 4-word question doesn't get clipped, and
    /// the pre-roll is left at 200 ms so the first phoneme survives the
    /// ~50 ms gap between hold-press and the audio engine going live.
    private final class Pump: ASRSamplePump, @unchecked Sendable {
        private let streamer: MoonshineStreamer
        private let gate: EnergyVADGate
        init(streamer: MoonshineStreamer) {
            self.streamer = streamer
            self.gate = EnergyVADGate(
                speechThresholdDb: -38,
                silenceThresholdDb: -50,
                holdSeconds: 0.50,
                preRollSeconds: 0.20
            )
        }
        func append(samples: [Float], sampleRate: Int32) {
            let forwarded = gate.gate(samples: samples)
            if !forwarded.isEmpty {
                streamer.append(samples: forwarded, sampleRate: sampleRate)
            }
        }
        /// Push samples straight to Moonshine, bypassing the VAD gate. Used
        /// by `QuestionASR.stop` to hand the encoder a trailing-silence
        /// bookend even though the gate would normally drop pure silence.
        /// Without this hatch the bookend never reaches the encoder and
        /// `LineCompleted` never fires for the final words.
        func appendBypassingGate(samples: [Float], sampleRate: Int32) {
            streamer.append(samples: samples, sampleRate: sampleRate)
        }
        func resetGate() { gate.reset() }
    }
}
