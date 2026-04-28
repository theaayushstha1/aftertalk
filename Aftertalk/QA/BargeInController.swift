import AVFoundation
import Foundation
import os

/// Listens to the mic during TTS playback so the user can interrupt the
/// assistant by simply starting to speak. This is the "auto barge-in" half
/// of CLAUDE.md's voice-loop spec; the hold-to-talk surface is the manual
/// half.
///
/// **Why AVAudioRecorder, not AVAudioEngine:** the first cut spun a private
/// `AVAudioEngine` and installed an input tap. Running a second engine on
/// the same `.playAndRecord` session that TTSWorker's Kokoro engine was
/// already using crashed reliably with `_dispatch_assert_queue_fail`
/// somewhere deep in CoreAudio's internal queue assertion when the
/// playback engine reconfigured its input bus. AVAudioRecorder coexists
/// with running playback engines because it is a high-level client of
/// the audio session, not another graph fighting for the same input
/// scope. We only need an energy estimate; we don't actually want the
/// audio. The recording file is in the system temp directory and is
/// dropped on `stop()`.
///
/// **VAD strategy (energy-based, no model):** AVAudioRecorder's
/// `averagePower(forChannel:)` returns dB FS values where 0 dB is full
/// scale and -160 dB is silence. We poll at 30 Hz (33 ms granularity) and
/// require sustained energy above `energyDbThreshold` for
/// `triggerHoldMillis` before firing. -32 dB sits comfortably above
/// ambient room noise (~-45 dB) and well below Kokoro's AEC-suppressed
/// playback bleed-back, so the controller does not false-trigger on the
/// assistant's own voice.
///
/// **Lifecycle:** caller invokes `start(onBargeIn:)` when entering
/// `.speaking` and `stop()` when leaving. Single-shot per `start` call —
/// once it triggers it stops itself before invoking the callback.
@MainActor
final class BargeInController {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "BargeIn")

    /// Average-power threshold in dB above which a meter sample counts
    /// as "voiced." Empirical floor on iPhone 17 Pro Max with the device
    /// on a desk, AirPods unplugged, room background ~30 dBA SPL. Tweak
    /// if real-world testing wants more or less sensitivity.
    private static let energyDbThreshold: Float = -32

    /// Sustained-energy hold required to fire. Below ~120 ms the
    /// controller false-triggers on Kokoro playback that slips past AEC;
    /// above ~250 ms it feels laggy when the user starts mid-sentence.
    private static let triggerHoldMillis: Double = 180

    /// Meter poll rate. 30 Hz = 33 ms granularity, matches the perceived
    /// responsiveness target without burning CPU.
    private static let pollHz: Double = 30

    private var recorder: AVAudioRecorder?
    private var pollTimer: Timer?
    private var fileURL: URL?
    private var onBargeIn: (() -> Void)?
    private var voicedSinceMillis: Double = 0
    private var didFire = false

    func start(onBargeIn: @escaping () -> Void) {
        if recorder != nil { stop() }
        self.onBargeIn = onBargeIn
        self.voicedSinceMillis = 0
        self.didFire = false

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bargein-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleIMA4,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.prepareToRecord(), r.record() else {
                log.error("recorder.record() returned false — barge-in disabled this turn")
                return
            }
            self.recorder = r
            self.fileURL = url
            // Add to .common so the poll timer keeps firing during
            // SwiftUI scroll-tracking — otherwise a user dragging the
            // chat scroll view freezes barge-in detection.
            let interval = 1.0 / Self.pollHz
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick(dtMillis: interval * 1000)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.pollTimer = timer
            log.info("barge-in armed (recorder, threshold=\(Self.energyDbThreshold, privacy: .public) dB, poll=\(Self.pollHz, privacy: .public) Hz)")
        } catch {
            log.error("recorder init failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let recorder {
            recorder.stop()
            self.recorder = nil
        }
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
        }
        onBargeIn = nil
        voicedSinceMillis = 0
        didFire = false
    }

    // MARK: - Private

    private func tick(dtMillis: Double) {
        guard !didFire, let r = recorder else { return }
        r.updateMeters()
        let avg = r.averagePower(forChannel: 0)
        if avg >= Self.energyDbThreshold {
            voicedSinceMillis += dtMillis
            if voicedSinceMillis >= Self.triggerHoldMillis {
                didFire = true
                let cb = onBargeIn
                stop()
                log.info("barge-in fired (avgDb=\(avg, privacy: .public))")
                cb?()
            }
        } else {
            // Decay rather than reset — short pauses inside speech
            // (consonant closures, breath gaps) shouldn't restart the
            // timer to zero.
            voicedSinceMillis = max(0, voicedSinceMillis - dtMillis)
        }
    }
}
