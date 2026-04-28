import Foundation
import SwiftData

@ModelActor
actor MeetingsRepository {
    func createMeeting(
        title: String,
        transcript: String,
        duration: Double,
        audioFileURL: URL? = nil
    ) throws -> UUID {
        let meeting = Meeting(
            title: title,
            recordedAt: .now,
            durationSeconds: duration,
            audioPath: nil,
            audioFileURL: audioFileURL,
            fullTranscript: transcript
        )
        modelContext.insert(meeting)
        try modelContext.save()
        return meeting.id
    }

    /// Replaces a meeting's transcript text in place. Used by the pipeline
    /// to swap the streaming Moonshine output for the higher-quality batch
    /// (Parakeet) transcript once it lands.
    func updateTranscript(meetingId: UUID, transcript: String) throws {
        guard let meeting = try fetchMeeting(meetingId) else { return }
        meeting.fullTranscript = transcript
        try modelContext.save()
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

    /// Returns the chat thread ID for the given meeting, creating one on first
    /// access. Per-meeting threads always have `isGlobal = false` and a non-nil
    /// `meetingId`; the global cross-meeting thread is created in Day 5.
    func chatThreadId(for meetingId: UUID) throws -> UUID {
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.meetingId == meetingId && $0.isGlobal == false }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            return existing.id
        }
        guard let meeting = try fetchMeeting(meetingId) else {
            throw QARepositoryError.meetingNotFound
        }
        let thread = ChatThread(meetingId: meetingId, isGlobal: false)
        modelContext.insert(thread)
        thread.meeting = meeting
        try modelContext.save()
        return thread.id
    }

    func appendChatMessage(threadId: UUID,
                            role: String,
                            text: String,
                            citations: [ChunkCitation] = []) throws {
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try modelContext.fetch(descriptor).first else {
            throw QARepositoryError.threadNotFound
        }
        let message = ChatMessage(role: role, text: text, citations: citations)
        modelContext.insert(message)
        message.thread = thread
        try modelContext.save()
    }

    private func fetchMeeting(_ id: UUID) throws -> Meeting? {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first
    }
}

enum QARepositoryError: Error, CustomStringConvertible {
    case meetingNotFound
    case threadNotFound

    var description: String {
        switch self {
        case .meetingNotFound: "Meeting not found."
        case .threadNotFound: "Chat thread not found."
        }
    }
}
