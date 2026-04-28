import Foundation
import SwiftData

@Model
final class SpeakerLabel {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var meetingId: UUID
    /// Stable Pyannote / FluidAudio speaker id ("Speaker_1", "Speaker_2", …).
    /// Nullable with default `nil` so existing SwiftData records migrate
    /// cleanly when diarization is unavailable. We key chunks → labels on
    /// this string, NOT on `id` (the UUID is purely SwiftData's primary key).
    var speakerId: String?
    var displayName: String
    var colorHex: String
    /// Mean of the per-segment 256-dim WeSpeaker embeddings, packed as
    /// little-endian Float32. Used for cross-meeting voice matching later.
    var embeddingCentroid: Data?
    /// First-seen timestamp inside this meeting, in seconds. Lets the UI
    /// order labels by who spoke first instead of by Pyannote's internal
    /// numbering. Nullable for backward compatibility.
    var firstSeenSec: Double?

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        speakerId: String? = nil,
        displayName: String,
        colorHex: String,
        embeddingCentroid: Data? = nil,
        firstSeenSec: Double? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.speakerId = speakerId
        self.displayName = displayName
        self.colorHex = colorHex
        self.embeddingCentroid = embeddingCentroid
        self.firstSeenSec = firstSeenSec
    }
}
