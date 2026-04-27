import Foundation
import SwiftData

@Model
final class SpeakerLabel {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var meetingId: UUID
    var displayName: String
    var colorHex: String
    var embeddingCentroid: Data?

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        displayName: String,
        colorHex: String,
        embeddingCentroid: Data? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.displayName = displayName
        self.colorHex = colorHex
        self.embeddingCentroid = embeddingCentroid
    }
}
