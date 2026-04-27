import Foundation
import os

enum ProcessingStage: Equatable, Sendable {
    case idle
    case savingMeeting
    case chunking
    case embedding(progress: Int, total: Int)
    case summarizing
    case done(meetingId: UUID, summaryLatencyMillis: Double)
    case failed(String)
}

@MainActor
@Observable
final class MeetingProcessingPipeline {
    var stage: ProcessingStage = .idle

    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Pipeline")
    private let repository: MeetingsRepository
    private let embeddings: any EmbeddingService
    private let llm: any LLMService
    private let chunker = ChunkIndexer()

    init(
        repository: MeetingsRepository,
        embeddings: any EmbeddingService,
        llm: any LLMService
    ) {
        self.repository = repository
        self.embeddings = embeddings
        self.llm = llm
    }

    func process(transcript: String, durationSeconds: Double) async -> UUID? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stage = .failed("empty transcript")
            return nil
        }
        do {
            stage = .savingMeeting
            let title = Self.suggestedTitle(from: transcript)
            let meetingId = try await repository.createMeeting(
                title: title,
                transcript: transcript,
                duration: durationSeconds
            )

            stage = .chunking
            let drafts = chunker.chunks(from: transcript, durationSeconds: durationSeconds)

            stage = .embedding(progress: 0, total: drafts.count)
            var vectors: [[Float]] = []
            vectors.reserveCapacity(drafts.count)
            for (i, draft) in drafts.enumerated() {
                let v = try await embeddings.embed(draft.text)
                vectors.append(v)
                stage = .embedding(progress: i + 1, total: drafts.count)
            }

            try await repository.attachChunks(to: meetingId, drafts: drafts, embeddings: vectors)

            // Meeting-level embedding from the full transcript head (~budgeted slice).
            let head = String(transcript.prefix(2000))
            let summaryEmbedding = try await embeddings.embed(head)
            try await repository.upsertSummaryEmbedding(meetingId: meetingId, embedding: summaryEmbedding)

            stage = .summarizing
            let started = ContinuousClock.now
            let result = try await llm.generateSummary(transcript: transcript)
            let elapsed = started.duration(to: .now)
            let latency = elapsed.aftertalkMillis
            try await repository.attachSummary(to: meetingId, summary: result.summary, latencyMillis: latency)

            stage = .done(meetingId: meetingId, summaryLatencyMillis: latency)
            return meetingId
        } catch {
            log.error("pipeline failed: \(String(describing: error), privacy: .public)")
            stage = .failed("\(error)")
            return nil
        }
    }

    static func suggestedTitle(from transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled meeting" }
        let firstSentence = ChunkIndexer.splitSentences(trimmed).first ?? trimmed
        let clipped = firstSentence.prefix(60)
        let suffix = firstSentence.count > 60 ? "…" : ""
        return String(clipped) + suffix
    }
}

extension Duration {
    var aftertalkMillis: Double {
        let comps = components
        return Double(comps.seconds) * 1000.0 + Double(comps.attoseconds) / 1e15
    }
}
