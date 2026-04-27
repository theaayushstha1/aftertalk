import Foundation
import SwiftData

@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String
    var recordedAt: Date
    var durationSeconds: Double
    var audioPath: String?
    var fullTranscript: String

    @Relationship(deleteRule: .cascade, inverse: \MeetingSummaryRecord.meeting)
    var summary: MeetingSummaryRecord?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptChunk.meeting)
    var chunks: [TranscriptChunk] = []

    @Relationship(deleteRule: .cascade, inverse: \SpeakerLabel.meeting)
    var speakers: [SpeakerLabel] = []

    @Relationship(deleteRule: .cascade, inverse: \ChatThread.meeting)
    var threads: [ChatThread] = []

    init(
        id: UUID = UUID(),
        title: String,
        recordedAt: Date = .now,
        durationSeconds: Double = 0,
        audioPath: String? = nil,
        fullTranscript: String = ""
    ) {
        self.id = id
        self.title = title
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.audioPath = audioPath
        self.fullTranscript = fullTranscript
    }
}
