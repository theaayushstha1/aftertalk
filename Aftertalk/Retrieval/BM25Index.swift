import Foundation
import SwiftData

/// Lexical (BM25) search over `TranscriptChunk` text. Built fresh for every
/// query — typical corpus is hundreds of chunks across a handful of
/// meetings, so building the inverted index on the fly is sub-millisecond
/// and avoids any persistence-side migration.
///
/// Why BM25 alongside dense retrieval (`SwiftDataVectorStore`):
///
/// `NLContextualEmbedding` is a transformer that averages token vectors.
/// It captures semantic similarity (paraphrase, synonyms, vague topical
/// match) but loses keyword precision: a question like "what did Jensen
/// say about the H100?" can score a chunk that mentions "the H200" higher
/// than the actual chunk with "H100" if the surrounding semantic context
/// is closer. BM25 fixes the opposite failure mode — it ranks by exact
/// keyword overlap weighted by inverse document frequency, so rare words
/// (proper nouns, model numbers, specific dates) carry signal.
///
/// We fuse the two via Reciprocal Rank Fusion (RRF) — the standard
/// production pattern. See `HierarchicalRetriever` for the fusion call;
/// see Cormack et al. 2009 (RRF) and Robertson & Zaragoza 2009 (BM25)
/// for the canonical references.
@ModelActor
actor BM25Index {
    /// Search chunks lexically. Returns hydrated `ChunkHit` objects ranked
    /// by BM25 — the same shape `SwiftDataVectorStore.searchChunks`
    /// returns — so the caller's RRF can fuse the two ranked lists and
    /// keep BM25-only hits in the final output. Earlier shape was just
    /// `(chunkId, score)` and the caller's lookup table only knew about
    /// dense hits, so a chunk that BM25 found but dense missed got
    /// silently dropped at the fusion step. That defeated the entire
    /// point of hybrid retrieval (dense paraphrase recall + BM25
    /// keyword precision); P1 fix returns full hits so RRF can keep
    /// them.
    ///
    /// `scopedTo` mirrors `SwiftDataVectorStore.searchChunks` so
    /// per-meeting and global retrieval share the same scoping path.
    func searchChunks(
        query: String,
        scopedTo meetingIds: [UUID]?,
        topK: Int
    ) throws -> [ChunkHit] {
        let queryTerms = Self.tokenize(query)
        guard !queryTerms.isEmpty else { return [] }

        let descriptor: FetchDescriptor<TranscriptChunk>
        if let ids = meetingIds, !ids.isEmpty {
            let scope = Set(ids)
            descriptor = FetchDescriptor<TranscriptChunk>(
                predicate: #Predicate { scope.contains($0.meetingId) }
            )
        } else {
            descriptor = FetchDescriptor<TranscriptChunk>()
        }
        let chunks = try modelContext.fetch(descriptor)
        guard !chunks.isEmpty else { return [] }

        // Build the inverted index for THIS query's term set only — we
        // don't need a full corpus-wide index because BM25's IDF only
        // matters for the terms the query actually contains.
        struct DocStats {
            let id: UUID
            let terms: [String: Int]
            let length: Int
        }
        var docs: [DocStats] = []
        docs.reserveCapacity(chunks.count)
        var docFreq: [String: Int] = [:]
        var chunkById: [UUID: TranscriptChunk] = [:]
        chunkById.reserveCapacity(chunks.count)
        for c in chunks {
            chunkById[c.id] = c
            let docTerms = Self.tokenize(c.text)
            var counts: [String: Int] = [:]
            for t in docTerms { counts[t, default: 0] += 1 }
            for q in queryTerms where counts[q] != nil {
                docFreq[q, default: 0] += 1
            }
            docs.append(DocStats(id: c.id, terms: counts, length: docTerms.count))
        }

        let N = Float(chunks.count)
        let avgDocLength: Float = {
            guard !docs.isEmpty else { return 1 }
            let total = docs.reduce(0) { $0 + $1.length }
            return Float(total) / Float(docs.count)
        }()

        let k1: Float = 1.5
        let b: Float = 0.75

        // Standard BM25:
        //   score = Σ_{t∈q} idf(t) · (tf(t,d) · (k1+1)) / (tf(t,d) + k1·(1 - b + b · |d|/avgdl))
        var scored: [(chunkId: UUID, score: Float)] = []
        scored.reserveCapacity(docs.count)
        for doc in docs {
            var s: Float = 0
            for q in queryTerms {
                guard let tf = doc.terms[q] else { continue }
                let df = Float(docFreq[q] ?? 0)
                // Robertson-Sparck-Jones IDF (max with 0 to avoid
                // negative IDF on terms appearing in >half the corpus).
                let idfRaw = logf((N - df + 0.5) / (df + 0.5) + 1)
                let idf = max(0, idfRaw)
                let tfFloat = Float(tf)
                let normalizedLength = 1 - b + b * (Float(doc.length) / avgDocLength)
                let numerator = tfFloat * (k1 + 1)
                let denominator = tfFloat + k1 * normalizedLength
                s += idf * (numerator / denominator)
            }
            if s > 0 { scored.append((chunkId: doc.id, score: s)) }
        }
        scored.sort { $0.score > $1.score }

        // Hydrate the top scored ids back into full `ChunkHit`s so the
        // fusion layer can carry BM25-only hits all the way to the
        // packer. We attach the BM25 raw score to the hit for now — the
        // grounding gate is tuned against cosine, but the gate runs on
        // `topScore` from the FUSED list and the fusion preserves
        // dense hits' cosine when both sources agree (the common case).
        // BM25-only outliers will surface with a BM25 score; that's
        // fine — the LLM still sees the chunk, and the gate's role of
        // "refuse on truly nothing" still works.
        var out: [ChunkHit] = []
        out.reserveCapacity(min(topK, scored.count))
        for entry in scored.prefix(topK) {
            guard let c = chunkById[entry.chunkId] else { continue }
            out.append(ChunkHit(
                chunkId: c.id,
                meetingId: c.meetingId,
                text: c.text,
                startSec: c.startSec,
                endSec: c.endSec,
                speakerName: c.speakerName,
                score: entry.score,
                orderIndex: c.orderIndex
            ))
        }
        return out
    }

    /// Lowercase + split on non-alphanumeric + drop length<2 + drop a
    /// small English stopword list. Good-enough preprocessing for
    /// meeting transcripts; doesn't try to do stemming because the
    /// corpus is small enough that morphological variation rarely
    /// matters and stemming introduces its own errors.
    nonisolated static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        out.reserveCapacity(max(8, text.count / 5))
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                if Self.acceptToken(current) { out.append(current) }
                current = ""
            }
        }
        if !current.isEmpty, Self.acceptToken(current) { out.append(current) }
        return out
    }

    private nonisolated static func acceptToken(_ t: String) -> Bool {
        guard t.count >= 2 else { return false }
        return !Self.stopwords.contains(t)
    }

    /// Small English stopword list. Tuned for meeting transcripts —
    /// keeps "i" out (single-char anyway), keeps "we" / "you" / "they"
    /// (might matter for who-said-what queries), drops articles,
    /// auxiliaries, and common conversational filler.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at",
        "for", "with", "by", "from", "as", "is", "are", "was", "were", "be",
        "been", "being", "have", "has", "had", "do", "does", "did",
        "will", "would", "could", "should", "may", "might", "can",
        "this", "that", "these", "those", "it", "its",
        "um", "uh", "yeah", "okay", "ok", "right", "so", "well",
        "like", "just", "really", "actually"
    ]
}
