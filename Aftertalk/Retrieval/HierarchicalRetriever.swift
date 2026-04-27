import Foundation

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

    init(embeddings: any EmbeddingService, store: any VectorStore, summaryTopK: Int = 5) {
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
            // Layer 1 (Day 5): pick the top-K meetings by summary embedding.
            // For Day 3 this branch only fires for global Q&A which we don't
            // expose yet, but the wiring is here so the upgrade is one step.
            let topMeetings = try await store.searchMeetings(query: queryVec, topK: summaryTopK)
            scope = topMeetings.isEmpty ? nil : topMeetings.map(\.meetingId)
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
