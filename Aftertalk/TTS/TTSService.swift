import AVFoundation
import Foundation
import os

protocol TTSService: AnyObject, Sendable {
    /// Queue a sentence for playback. Sentences play in order.
    func speak(_ sentence: String) async
    /// Stop immediately, dropping any queued text. Used for barge-in (Day 5).
    func stop() async
}

/// Day 3 placeholder TTS. AVSpeechSynthesizer manages its own audio session, so
/// we deactivate the recording session before the first .speak call. Kokoro
/// neural TTS swaps in on Day 4 behind this same protocol.
final class AVSpeechSynthesizerTTS: NSObject, TTSService, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "TTS")
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice
    private let queue = DispatchQueue(label: "com.theaayushstha.aftertalk.tts")
    private nonisolated(unsafe) var firstSpokenSignaled = false
    private nonisolated(unsafe) var firstSpokenContinuation: CheckedContinuation<Void, Never>?

    override init() {
        let preferred = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe")
            ?? AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)!
        self.voice = preferred
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ sentence: String) async {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.synthesizer.stopSpeaking(at: .immediate)
                self?.firstSpokenSignaled = false
                cont.resume()
            }
        }
    }

    /// Awaits the first sample of the first queued utterance. Useful for
    /// measuring time-to-first-spoken-word in the Q&A perf budget.
    func awaitFirstSpoken() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                if self.firstSpokenSignaled {
                    cont.resume()
                } else {
                    self.firstSpokenContinuation = cont
                }
            }
        }
    }

    /// AVSpeechSynthesizerDelegate. Fires the first time any sample plays.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        willSpeakRangeOfSpeechString characterRange: NSRange,
                                        utterance: AVSpeechUtterance) {
        queue.async { [weak self] in
            guard let self, !self.firstSpokenSignaled else { return }
            self.firstSpokenSignaled = true
            self.firstSpokenContinuation?.resume()
            self.firstSpokenContinuation = nil
        }
    }
}
