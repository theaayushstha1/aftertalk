import Foundation
import SwiftData

@ModelActor
actor MeetingsRepository {
    func createMeeting(title: String, transcript: String, duration: Double) throws -> UUID {
        let meeting = Meeting(
            title: title,
            recordedAt: .now,
            durationSeconds: duration,
            audioPath: nil,
            fullTranscript: transcript
        )
        modelContext.insert(meeting)
        try modelContext.save()
        return meeting.id
    }

    func attachSummary(to meetingId: UUID, summary: MeetingSummary, latencyMillis: Double) throws {
        guard let meeting = try fetchMeeting(meetingId) else { return }
        let record = MeetingSummaryRecord(
            decisions: summary.decisions,
            actionItems: summary.actionItems.map { ActionItemRecord(description: $0.description, owner: $0.owner) },
            topics: summary.topics,
            openQuestions: summary.openQuestions,
            generatedAt: .now,
            generationLatencyMillis: latencyMillis
        )
        modelContext.insert(record)
        meeting.summary = record
        try modelContext.save()
    }

    func attachChunks(to meetingId: UUID, drafts: [ChunkDraft], embeddings: [[Float]]) throws {
        guard drafts.count == embeddings.count, let meeting = try fetchMeeting(meetingId) else { return }
        for (draft, vec) in zip(drafts, embeddings) {
            let bytes = SwiftDataVectorStore.encode(vec)
            let chunk = TranscriptChunk(
                meetingId: meetingId,
                orderIndex: draft.orderIndex,
                text: draft.text,
                startSec: draft.startSec,
                endSec: draft.endSec,
                speakerName: draft.speakerName,
                embedding: bytes,
                embeddingDim: vec.count
            )
            chunk.meeting = meeting
            modelContext.insert(chunk)
        }
        try modelContext.save()
    }

    func upsertSummaryEmbedding(meetingId: UUID, embedding: [Float]) throws {
        let bytes = SwiftDataVectorStore.encode(embedding)
        let descriptor = FetchDescriptor<MeetingSummaryEmbedding>(
            predicate: #Predicate { $0.meetingId == meetingId }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            existing.embedding = bytes
            existing.embeddingDim = embedding.count
        } else {
            let row = MeetingSummaryEmbedding(meetingId: meetingId, embedding: bytes, embeddingDim: embedding.count)
            modelContext.insert(row)
        }
        try modelContext.save()
    }

    func renameMeeting(_ meetingId: UUID, to title: String) throws {
        guard let meeting = try fetchMeeting(meetingId) else { return }
        meeting.title = title
        try modelContext.save()
    }

    func deleteMeeting(_ meetingId: UUID) throws {
        guard let meeting = try fetchMeeting(meetingId) else { return }
        modelContext.delete(meeting)
        try modelContext.save()
    }

    private func fetchMeeting(_ id: UUID) throws -> Meeting? {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first
    }
}
