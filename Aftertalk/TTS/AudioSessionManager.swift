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
    enum Mode: Equatable { case none, recording, voiceChat }
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

    /// Q&A mode: `.playAndRecord` + `.voiceChat` so we can listen to the user
    /// AND speak the answer back through the same active session. AEC is
    /// requested via `setPrefersEchoCancelledInput` so the mic can stay armed
    /// during TTS playback for barge-in (Day 5). Order is the canonical one
    /// from WWDC23/10235 — flipping it silently disables echo cancellation.
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
                options: [.defaultToSpeaker, .allowBluetooth]
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
