import Foundation
import SwiftData

@Model
final class MeetingSummaryEmbedding {
    @Attribute(.unique) var id: UUID
    var meetingId: UUID
    var embedding: Data
    var embeddingDim: Int

    init(id: UUID = UUID(), meetingId: UUID, embedding: Data, embeddingDim: Int) {
        self.id = id
        self.meetingId = meetingId
        self.embedding = embedding
        self.embeddingDim = embeddingDim
    }
}
