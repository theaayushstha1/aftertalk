import Foundation

/// One contiguous span of speech attributed to a single speaker by Pyannote +
/// WeSpeaker. `speakerId` is the stable string FluidAudio's `SpeakerManager`
/// hands back ("Speaker_1", "Speaker_2", …) — same id across chunks for the
/// same voice, as long as the underlying `DiarizerManager` instance is reused.
///
/// `embedding` is the 256-dim L2-normalized WeSpeaker embedding for this
/// segment. We persist the per-speaker centroid (mean across that speaker's
/// segments) into `SpeakerLabel.embeddingCentroid` so we can match voices
/// across meetings later (Day 6 stretch).
struct SpeakerSegment: Sendable, Equatable {
    let speakerId: String
    let startSec: Double
    let endSec: Double
    let embedding: [Float]   // 256-dim WeSpeaker
    let qualityScore: Float

    init(
        speakerId: String,
        startSec: Double,
        endSec: Double,
        embedding: [Float],
        qualityScore: Float
    ) {
        self.speakerId = speakerId
        self.startSec = startSec
        self.endSec = endSec
        self.embedding = embedding
        self.qualityScore = qualityScore
    }
}

enum DiarizationError: Error, CustomStringConvertible, Sendable {
    case modelMissing(String)
    case audioUnreadable(URL)
    case inferenceFailed(any Error)

    var description: String {
        switch self {
        case .modelMissing(let why): "Diarization model missing: \(why)"
        case .audioUnreadable(let url): "Cannot read audio at \(url.path)"
        case .inferenceFailed(let err): "Diarization failed: \(String(describing: err))"
        }
    }
}

/// Loads Pyannote segmentation + WeSpeaker embedding once and runs offline
/// speaker diarization over a recorded WAV. `warm()` is idempotent and may
/// be called eagerly on app start; `diarize(audioFile:)` reads the file off
/// disk and returns a sorted, non-overlapping `[SpeakerSegment]` covering
/// the speech regions. Implementations must not perform any network IO;
/// weights ship as bundled resources mirroring the Parakeet pattern.
protocol DiarizationService: Sendable {
    func warm() async throws
    func diarize(audioFile: URL) async throws -> [SpeakerSegment]
    func cleanup() async
}
