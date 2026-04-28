import AVFoundation
import Foundation
import os

/// Listens to the mic during TTS playback so the user can interrupt the
/// assistant by simply starting to speak — no button press required. This is
/// the "auto barge-in" half of CLAUDE.md's voice-loop spec; the hold-to-talk
/// surface in `ChatThreadView` / `GlobalChatView` is the manual half.
///
/// **Why a separate engine:** the meeting recorder's `AudioCaptureService`
/// and the Q&A `QuestionASR` both own their own `AVAudioEngine`, and during
/// `.speaking` neither one is running. AVAudioEngine input taps are exclusive
/// per engine, so we spin a small dedicated engine here whose only job is to
/// pull mic frames and compute RMS energy. The audio session is already in
/// `.voiceChat` mode (configured in `QuestionASR.start()`), which means
/// Apple's voice-processing IO unit is active and we get echo cancellation
/// for free — without AEC the mic would trigger barge-in on Kokoro's own
/// playback bleed-back through the speaker.
///
/// **VAD strategy (energy-based, no model):** we compute root-mean-square
/// over each tap callback (~1024 frames at the device's input rate, ≈ 21 ms
/// at 48 kHz) and require sustained energy above a fixed threshold for
/// `triggerHoldMillis` before firing. This is intentionally simpler than
/// TEN-VAD or Silero — those are next on the list, but for the first cut,
/// a 0.025 RMS gate + 180 ms hysteresis already cleanly distinguishes spoken
/// voice from background hum on iPhone 17 Pro Max. The threshold lives in a
/// constant we can tune live in the debug overlay if it misfires in noisy
/// environments.
///
/// **Lifecycle:** caller invokes `start(onBargeIn:)` when entering `.speaking`
/// and `stop()` when leaving any of `.idle`, `.failed`, or after `onBargeIn`
/// has fired. The controller is single-shot per `start` — once it triggers it
/// stops itself, so the caller does not need to debounce. Restarting requires
/// a fresh `start` call.
@MainActor
final class BargeInController {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "BargeIn")

    /// RMS threshold above which a tap callback's frame block counts as
    /// "voiced." Empirical floor on iPhone 17 Pro Max with the device on a
    /// desk, AirPods unplugged, room background ~30 dBA. Tweak in
    /// `debugTuneThreshold(_:)` if real-world testing wants more or less
    /// sensitivity.
    private static let energyThreshold: Float = 0.025

    /// How long energy must stay above threshold before we fire. Below ~120 ms
    /// the controller false-triggers on Kokoro's own playback (slip past AEC),
    /// above ~250 ms it feels laggy when the user starts mid-sentence.
    private static let triggerHoldMillis: Double = 180

    nonisolated(unsafe) private var engine: AVAudioEngine?
    private var onBargeIn: (() -> Void)?
    private var voicedSinceMillis: Double = 0
    private var lastTapTimestamp: ContinuousClock.Instant?
    private var didFire = false

    /// Begin listening. `onBargeIn` is invoked on the main actor exactly once
    /// per `start` call when the user's voice crosses the trigger; the
    /// controller stops itself before invoking it.
    func start(onBargeIn: @escaping () -> Void) {
        if engine != nil { stop() }
        self.onBargeIn = onBargeIn
        self.voicedSinceMillis = 0
        self.lastTapTimestamp = nil
        self.didFire = false

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // 0 Hz = audio session not active or input unavailable — bail loudly.
        guard format.sampleRate > 0 else {
            log.warning("input format unavailable — barge-in disabled for this turn")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = Self.rms(of: buffer)
            Task { @MainActor [weak self] in
                self?.handle(rms: rms)
            }
        }

        do {
            try engine.start()
            self.engine = engine
            log.info("barge-in armed at \(format.sampleRate, privacy: .public) Hz, threshold=\(Self.energyThreshold, privacy: .public)")
        } catch {
            input.removeTap(onBus: 0)
            log.error("engine start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        onBargeIn = nil
        voicedSinceMillis = 0
        lastTapTimestamp = nil
        didFire = false
    }

    // MARK: - Private

    private func handle(rms: Float) {
        guard !didFire, engine != nil else { return }
        let now = ContinuousClock.now
        let dtMillis: Double = {
            guard let last = lastTapTimestamp else { return 0 }
            return last.duration(to: now).aftertalkMillis
        }()
        lastTapTimestamp = now

        if rms >= Self.energyThreshold {
            voicedSinceMillis += dtMillis
            if voicedSinceMillis >= Self.triggerHoldMillis {
                didFire = true
                let cb = onBargeIn
                stop()
                log.info("barge-in fired (rms=\(rms, privacy: .public))")
                cb?()
            }
        } else {
            // Decay rather than reset — short pauses inside speech (consonant
            // closures, breath gaps) shouldn't restart the timer to zero.
            voicedSinceMillis = max(0, voicedSinceMillis - dtMillis)
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sumSq: Float = 0
        for i in 0..<n {
            let s = channelData[i]
            sumSq += s * s
        }
        return (sumSq / Float(n)).squareRoot()
    }
}
