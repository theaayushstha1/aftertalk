import Foundation
import SwiftData

@Model
final class TranscriptChunk {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var meetingId: UUID
    var orderIndex: Int
    var text: String
    var startSec: Double
    var endSec: Double
    var speakerName: String?
    /// Stable Pyannote speaker ID ("Speaker_1", "Speaker_2", …) assigned by
    /// FluidAudio's `SpeakerManager`. Nullable with default `nil` so existing
    /// SwiftData records migrate cleanly when diarization is unavailable
    /// (no model bundle, fall-through path).
    var speakerId: String?
    var embedding: Data
    var embeddingDim: Int

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        orderIndex: Int,
        text: String,
        startSec: Double,
        endSec: Double,
        speakerName: String? = nil,
        speakerId: String? = nil,
        embedding: Data,
        embeddingDim: Int
    ) {
        self.id = id
        self.meetingId = meetingId
        self.orderIndex = orderIndex
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.speakerName = speakerName
        self.speakerId = speakerId
        self.embedding = embedding
        self.embeddingDim = embeddingDim
    }
}
