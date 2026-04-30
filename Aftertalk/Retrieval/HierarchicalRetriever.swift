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
    private let bm25: BM25Index?
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

    init(embeddings: any EmbeddingService,
         store: any VectorStore,
         bm25: BM25Index? = nil,
         summaryTopK: Int = 8) {
        self.embeddings = embeddings
        self.store = store
        self.bm25 = bm25
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
        // Hybrid retrieval: dense (semantic) + BM25 (lexical) → RRF fusion.
        // Both lookups use a wider topK (3× the requested final size) so
        // RRF has room to mix rankings instead of just intersecting two
        // tiny sets. Dense catches paraphrase / topical match; BM25
        // catches keyword precision (proper nouns, model numbers, dates,
        // exact phrases). When `bm25` is nil (legacy callers / tests),
        // we fall back to dense-only — preserves existing behaviour for
        // anything not yet upgraded.
        let widenedK = max(query.topKChunks * 3, 24)
        async let denseHits = store.searchChunks(query: queryVec, scopedTo: scope, topK: widenedK)
        async let bm25Hits: [(chunkId: UUID, score: Float)] = {
            guard let bm25 else { return [] }
            return (try? await bm25.searchChunks(query: trimmed, scopedTo: scope, topK: widenedK)) ?? []
        }()
        let dense = try await denseHits
        let bm25List = await bm25Hits
        let chunks = Self.fuseRRF(dense: dense, bm25: bm25List, topK: query.topKChunks)

        let searchMs = searchStart.duration(to: .now).aftertalkMillis
        log.info("retrieve: dense=\(dense.count, privacy: .public) bm25=\(bm25List.count, privacy: .public) → fused=\(chunks.count, privacy: .public)")

        return RetrievalResult(
            chunks: chunks,
            topScore: chunks.first?.score ?? 0,
            queryEmbeddingMillis: embedMs,
            searchMillis: searchMs
        )
    }

    /// Reciprocal Rank Fusion. Standard formula:
    ///   rrf_score(d) = Σ_{r in retrievers} 1 / (k + rank_r(d))
    /// where rank starts at 1 and `k=60` is the canonical constant from
    /// Cormack et al. — robust to wildly different score scales between
    /// dense (cosine [0,1]) and BM25 (unbounded), which is exactly why
    /// we use it instead of a weighted score sum.
    ///
    /// The fused result is re-sorted by RRF score and we take the top
    /// `topK`. Each returned `ChunkHit` carries the original DENSE
    /// `score` (cosine) so downstream code that reads `topScore` still
    /// gets a familiar signal — we don't replace cosine with RRF
    /// because the orchestrator's grounding gate is tuned against
    /// cosine. RRF is a re-ranker, not a score replacer.
    static func fuseRRF(
        dense: [ChunkHit],
        bm25: [(chunkId: UUID, score: Float)],
        topK: Int
    ) -> [ChunkHit] {
        let k: Float = 60
        var rrf: [UUID: Float] = [:]
        var lookup: [UUID: ChunkHit] = [:]
        for (rank, hit) in dense.enumerated() {
            rrf[hit.chunkId, default: 0] += 1.0 / (k + Float(rank + 1))
            lookup[hit.chunkId] = hit
        }
        for (rank, entry) in bm25.enumerated() {
            rrf[entry.chunkId, default: 0] += 1.0 / (k + Float(rank + 1))
            // BM25-only hits without a dense ChunkHit can't contribute
            // to the result (we don't have the chunk's text/timing on
            // hand here). They still influence the RRF ranking when
            // they coincide with a dense hit, which is the common case.
        }
        let sorted = rrf.sorted { $0.value > $1.value }
        var out: [ChunkHit] = []
        out.reserveCapacity(min(topK, sorted.count))
        for (id, _) in sorted {
            guard let hit = lookup[id] else { continue }
            out.append(hit)
            if out.count >= topK { break }
        }
        return out
    }
}
