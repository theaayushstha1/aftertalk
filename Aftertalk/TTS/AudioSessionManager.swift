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

    private var isConfigured = false
    private var interruptionTask: Task<Void, Never>?

    private init() {}

    func configureForRecording() throws(AudioSessionError) {
        // Day 1: ASR-only. Use .record + .measurement for clean mic capture.
        // Day 4 swaps to .playAndRecord + .voiceChat when Kokoro TTS lands so AEC kicks in.
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

        isConfigured = true
        observeInterruptions()
    }

    func deactivate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isConfigured = false
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
