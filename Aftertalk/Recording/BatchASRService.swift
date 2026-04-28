import Foundation

/// Output of a batch (post-recording) high-quality transcription pass.
/// Distinct from the streaming `TranscriptDelta` because batch runs offer
/// punctuation, casing, and word-accurate timestamps that streaming ASR
/// either omits or only approximates.
struct CanonicalTranscript: Sendable, Equatable {
    struct WordTiming: Sendable, Equatable {
        let text: String
        let startSec: Double
        let endSec: Double
        init(text: String, startSec: Double, endSec: Double) {
            self.text = text; self.startSec = startSec; self.endSec = endSec
        }
    }
    let text: String
    let words: [WordTiming]
    let durationSec: Double
    let backend: String
    init(text: String, words: [WordTiming], durationSec: Double, backend: String) {
        self.text = text; self.words = words; self.durationSec = durationSec; self.backend = backend
    }
}

enum BatchASRError: Error, CustomStringConvertible, Sendable {
    case modelMissing(String)
    case audioUnreadable(URL)
    case transcriptionFailed(String)

    var description: String {
        switch self {
        case .modelMissing(let why): "Batch ASR model missing: \(why)"
        case .audioUnreadable(let url): "Cannot read audio at \(url.path)"
        case .transcriptionFailed(let why): "Batch ASR failed: \(why)"
        }
    }
}

/// Loads a model once and transcribes WAV files end-to-end.
/// `warm()` is idempotent and may be called eagerly on app start to amortize
/// the ~3-4s Core ML compile cost. `transcribe(audioFile:)` reads PCM samples
/// from the file and returns the canonical transcript. Implementations must
/// not perform any network IO; weights ship as bundled resources.
protocol BatchASRService: AnyObject, Sendable {
    func warm() async throws
    func transcribe(audioFile: URL) async throws -> CanonicalTranscript
    func cleanup() async
}
