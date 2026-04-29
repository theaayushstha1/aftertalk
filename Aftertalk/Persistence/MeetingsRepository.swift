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
                speakerId: draft.speakerId,
                embedding: bytes,
                embeddingDim: vec.count
            )
            chunk.meeting = meeting
            modelContext.insert(chunk)
        }
        try modelContext.save()
    }

    /// Persist the per-meeting speaker roster produced by Pyannote diarization.
    /// Each entry maps a stable `speakerId` to a UI display name + color +
    /// 256-dim WeSpeaker centroid (mean of that speaker's segment embeddings).
    /// Replaces any existing labels for the meeting (idempotent rerun).
    func attachSpeakers(to meetingId: UUID, drafts: [SpeakerLabelDraft]) throws {
        guard let meeting = try fetchMeeting(meetingId) else { return }
        // Wipe existing labels first — diarization is allowed to be re-run.
        for existing in meeting.speakers {
            modelContext.delete(existing)
        }
        for draft in drafts {
            let label = SpeakerLabel(
                meetingId: meetingId,
                speakerId: draft.speakerId,
                displayName: draft.displayName,
                colorHex: draft.colorHex,
                embeddingCentroid: draft.embeddingCentroid,
                firstSeenSec: draft.firstSeenSec
            )
            label.meeting = meeting
            modelContext.insert(label)
        }
        try modelContext.save()
    }

    func upsertSummaryEmbedding(meetingId: UUID, embedding: [Float]) async throws {
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

    /// Returns (and lazily creates) the singleton global cross-meeting thread.
    /// Always `isGlobal = true`, `meetingId = nil`. Backs the "Ask" tab so the
    /// user can query across every recorded meeting in one place.
    func globalChatThreadId() throws -> UUID {
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.isGlobal == true }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            return existing.id
        }
        let thread = ChatThread(meetingId: nil, isGlobal: true)
        modelContext.insert(thread)
        try modelContext.save()
        return thread.id
    }

    /// Snapshot of the metadata the global chat path needs from a set of
    /// meeting IDs: title for citation pills, structured summary fields for
    /// the cross-meeting overview block. Order matches the input array;
    /// missing IDs are dropped. Returns plain values rather than `@Model`
    /// references so the result is safe to ferry across the actor boundary.
    func meetingHeaders(for meetingIds: [UUID]) throws -> [MeetingHeader] {
        guard !meetingIds.isEmpty else { return [] }
        let scope = Set(meetingIds)
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { scope.contains($0.id) }
        )
        let meetings = try modelContext.fetch(descriptor)
        let byId = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        return meetingIds.compactMap { id in
            guard let m = byId[id] else { return nil }
            let summary: MeetingHeader.SummarySnapshot? = m.summary.map { rec in
                MeetingHeader.SummarySnapshot(
                    decisions: rec.decisions,
                    topics: rec.topics,
                    actionItems: rec.actionItems.map { ($0.description, $0.owner) },
                    openQuestions: rec.openQuestions
                )
            }
            return MeetingHeader(
                id: m.id,
                title: m.title,
                recordedAt: m.recordedAt,
                summary: summary
            )
        }
    }

    /// Lightweight roster for the global Q&A metadata router: every meeting in
    /// the store, ordered newest-first, projected down to the
    /// `Sendable`-friendly `MeetingHeader` shape so it crosses the actor
    /// boundary cleanly. Used by `QAOrchestrator.runAskGlobal` to short-circuit
    /// trivial questions like "how many meetings have I had" without touching
    /// the retriever or LLM.
    func allMeetingHeaders() throws -> [MeetingHeader] {
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.summary]
        let meetings = try modelContext.fetch(descriptor)
        return meetings.map { m in
            let summary: MeetingHeader.SummarySnapshot? = m.summary.map { rec in
                MeetingHeader.SummarySnapshot(
                    decisions: rec.decisions,
                    topics: rec.topics,
                    actionItems: rec.actionItems.map { ($0.description, $0.owner) },
                    openQuestions: rec.openQuestions
                )
            }
            return MeetingHeader(
                id: m.id,
                title: m.title,
                recordedAt: m.recordedAt,
                summary: summary
            )
        }
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

/// Sendable snapshot of meeting metadata. Carries the `MeetingSummaryRecord`
/// reference straight from SwiftData — that's an `@Model` class so it stays
/// live as long as a fetch context retains it. Used by the global Q&A path
/// (which doesn't have a single `Meeting` to scope against).
struct MeetingHeader: Sendable {
    let id: UUID
    let title: String
    let recordedAt: Date
    let summary: SummarySnapshot?

    struct SummarySnapshot: Sendable {
        let decisions: [String]
        let topics: [String]
        /// (description, owner) tuples — matches `ActionItemRecord` shape.
        let actionItems: [(String, String?)]
        let openQuestions: [String]
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
