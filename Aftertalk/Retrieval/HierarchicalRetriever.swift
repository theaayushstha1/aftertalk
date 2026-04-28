import Foundation
import os

struct RetrievalQuery: Sendable {
    let text: String
    let scopedToMeeting: UUID?
    let topKChunks: Int

    init(text: String, scopedToMeeting: UUID? = nil, topKChunks: Int = 8) {
        self.text = text
        self.scopedToMeeting = scopedToMeeting
        self.topKChunks = topKChunks
    }
}

struct RetrievalResult: Sendable {
    let chunks: [ChunkHit]
    let topScore: Float
    let queryEmbeddingMillis: Double
    let searchMillis: Double

    var isEmpty: Bool { chunks.isEmpty }
}

protocol Retriever: Sendable {
    func retrieve(_ query: RetrievalQuery) async throws -> RetrievalResult
}

/// Day 3 ships per-meeting retrieval (Layer 2 only). Day 5 adds the Layer-1
/// summary search to scope across multiple meetings. Same protocol, drop-in
/// upgrade.
final class HierarchicalRetriever: Retriever, @unchecked Sendable {
    private let embeddings: any EmbeddingService
    private let store: any VectorStore
    private let summaryTopK: Int
    /// Absolute floor — an off-topic meeting whose cosine to the question is
    /// near random noise should not contribute citations regardless of how
    /// many meetings exist. 0.12 sits a hair above NLContextualEmbedding's
    /// typical noise floor of ~0.10. We dropped the relative cutoff because
    /// it was masking newly-recorded meetings on the global Ask tab: a
    /// question like "any meeting that discussed anxiety?" would route to
    /// the older meeting that mentioned anxiety in passing, and the new
    /// meeting (whose summary embedding sat ~0.05 below the top score) got
    /// pruned. With six meetings live on a phone, scanning all of them at
    /// Layer 2 is faster than the routing decision anyway.
    private static let summaryAbsoluteFloor: Float = 0.12
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Retriever")

    init(embeddings: any EmbeddingService, store: any VectorStore, summaryTopK: Int = 8) {
        self.embeddings = embeddings
        self.store = store
        self.summaryTopK = summaryTopK
    }

    func retrieve(_ query: RetrievalQuery) async throws -> RetrievalResult {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RetrievalResult(chunks: [], topScore: 0, queryEmbeddingMillis: 0, searchMillis: 0)
        }

        let embedStart = ContinuousClock.now
        let queryVec = try await embeddings.embed(trimmed)
        let embedMs = embedStart.duration(to: .now).aftertalkMillis

        let searchStart = ContinuousClock.now
        let scope: [UUID]?
        if let pinned = query.scopedToMeeting {
            scope = [pinned]
        } else {
            // Layer 1: pick the top-K meetings by summary embedding, then
            // apply a relative + absolute filter so weak matches don't pollute
            // citations on questions that are really scoped to one meeting.
            let topMeetings = try await store.searchMeetings(query: queryVec, topK: summaryTopK)
            if topMeetings.isEmpty {
                scope = nil
            } else {
                let filtered = topMeetings.filter { $0.score >= Self.summaryAbsoluteFloor }
                let dropped = topMeetings.count - filtered.count
                if dropped > 0 {
                    log.info("layer-1 floor dropped \(dropped, privacy: .public) meetings below \(Self.summaryAbsoluteFloor, privacy: .public)")
                }
                // If everything sits below the noise floor (off-topic question,
                // or all meetings are loosely related), fall through to a
                // library-wide chunk search rather than starving the prompt.
                scope = filtered.isEmpty ? nil : filtered.map(\.meetingId)
            }
        }
        let chunks = try await store.searchChunks(query: queryVec, scopedTo: scope, topK: query.topKChunks)
        let searchMs = searchStart.duration(to: .now).aftertalkMillis

        return RetrievalResult(
            chunks: chunks,
            topScore: chunks.first?.score ?? 0,
            queryEmbeddingMillis: embedMs,
            searchMillis: searchMs
        )
    }
}
