import AVFoundation
import Foundation

enum AudioSessionError: Error, CustomStringConvertible {
    case configureFailed(any Error)
    case activateFailed(any Error)

    var description: String {
        switch self {
        case .configureFailed(let e): return "Audio session configure failed: \(e)"
        case .activateFailed(let e): return "Audio session activate failed: \(e)"
        }
    }
}

actor AudioSessionManager {
    static let shared = AudioSessionManager()

    /// Tracks the active configuration so back-to-back transitions skip the
    /// expensive setCategory + setActive dance when nothing actually changed.
    enum Mode: Equatable { case none, recording, voiceChat, voiceQuestion }
    private var mode: Mode = .none
    private var interruptionTask: Task<Void, Never>?

    private init() {}

    /// Meeting-capture mode: `.record` + `.measurement` for clean,
    /// minimally-processed mic input that keeps Parakeet/Moonshine WER low.
    /// Output is disabled in this category — do **not** call this if a TTS
    /// playback is about to follow.
    func configureForRecording() throws(AudioSessionError) {
        if mode == .recording { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
        } catch {
            throw .configureFailed(error)
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw .activateFailed(error)
        }
        mode = .recording
        observeInterruptions()
    }

    /// Q&A listening mode: `.playAndRecord` + `.measurement` so the mic
    /// delivers raw, minimally-processed audio while the output bus stays
    /// available for whatever Kokoro was doing. We use this while the user
    /// holds the mic to ask a question — Apple's voice-processing IO unit
    /// (which is what `.voiceChat` engages) applies aggressive AGC, noise
    /// suppression, and a 300-3400 Hz voice band-pass that smears formants
    /// and demonstrably hurts Moonshine WER on free-form questions.
    /// `.measurement` matches what the meeting recorder uses, so question
    /// transcription quality matches meeting transcription quality. We turn
    /// AEC off here too (no TTS is playing, so there is no echo to cancel).
    /// The orchestrator flips back to `.voiceChat` before TTS starts so the
    /// barge-in mic gets AEC against Kokoro's playback bleed.
    func configureForVoiceQuestion() throws(AudioSessionError) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
        } catch {
            throw .configureFailed(error)
        }
        if #available(iOS 18.0, *) {
            try? session.setPrefersEchoCancelledInput(false)
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw .activateFailed(error)
        }
        mode = .voiceQuestion
        observeInterruptions()
    }

    /// Q&A speaking mode: `.playAndRecord` + `.voiceChat` so Kokoro plays the
    /// answer through the active session and the auto barge-in's mic gets
    /// echo cancellation against the assistant's own voice. AEC is requested
    /// via `setPrefersEchoCancelledInput`. Order is the canonical one from
    /// WWDC23/10235 — flipping it silently disables echo cancellation.
    func configureForVoiceChat() throws(AudioSessionError) {
        // No early-return on `mode == .voiceChat`. iOS can implicitly
        // deactivate the session out from under us (interruption, route
        // change, brief background) without our cached `mode` knowing,
        // which leads to setActive() failing on the *next* hold-to-ask
        // because the OS sees an active node graph against an inactive
        // session. setCategory + setActive are both effectively no-ops
        // when values already match — pay the few ms every time and
        // guarantee the session is healthy.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                // `.duckOthers` lowers any music/podcast playing in another app
                // for the duration of the TTS reply so the user hears Aftertalk
                // clearly without needing to pause Spotify first. Restored
                // automatically on deactivate via `.notifyOthersOnDeactivation`.
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
        } catch {
            throw .configureFailed(error)
        }
        // setPrefersEchoCancelledInput is iOS 18+; available on our iOS 26 target.
        if #available(iOS 18.0, *) {
            try? session.setPrefersEchoCancelledInput(true)
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw .activateFailed(error)
        }
        mode = .voiceChat
        observeInterruptions()
    }

    func deactivate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        mode = .none
        interruptionTask?.cancel()
        interruptionTask = nil
    }

    private func observeInterruptions() {
        interruptionTask?.cancel()
        interruptionTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
            for await note in stream {
                guard !Task.isCancelled else { return }
                let info = note.userInfo
                let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt
                await self?.handle(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }
    }

    private func handle(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let raw = typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            break
        case .ended:
            if let optionsRaw {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
            }
        @unknown default:
            break
        }
    }
}
