import Foundation
import SwiftData

struct ChunkHit: Sendable {
    let chunkId: UUID
    let meetingId: UUID
    let text: String
    let startSec: Double
    let endSec: Double
    let speakerName: String?
    let score: Float
    let orderIndex: Int
}

protocol VectorStore: Sendable {
    func upsertMeetingSummary(meetingId: UUID, embedding: [Float]) async throws
    func searchChunks(query: [Float], scopedTo meetingIds: [UUID]?, topK: Int) async throws -> [ChunkHit]
    func searchMeetings(query: [Float], topK: Int) async throws -> [(meetingId: UUID, score: Float)]
}

/// Day-2 vector store: in-memory cosine over SwiftData blobs.
/// Trade-off: O(n) per query, fine for thousands of chunks.
/// Swap to sqlite-vec or VecturaKit when meeting count climbs into the tens.
@ModelActor
actor SwiftDataVectorStore: VectorStore {
    func upsertMeetingSummary(meetingId: UUID, embedding: [Float]) async throws {
        let bytes = Self.encode(embedding)
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

    func searchChunks(query: [Float], scopedTo meetingIds: [UUID]?, topK: Int) async throws -> [ChunkHit] {
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
        let queryNorm = Self.l2Norm(query)
        var hits: [ChunkHit] = []
        hits.reserveCapacity(chunks.count)
        for c in chunks {
            let v = Self.decode(c.embedding, dim: c.embeddingDim)
            let s = Self.cosine(query, v, qNorm: queryNorm)
            hits.append(ChunkHit(
                chunkId: c.id,
                meetingId: c.meetingId,
                text: c.text,
                startSec: c.startSec,
                endSec: c.endSec,
                speakerName: c.speakerName,
                score: s,
                orderIndex: c.orderIndex
            ))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(topK))
    }

    func searchMeetings(query: [Float], topK: Int) async throws -> [(meetingId: UUID, score: Float)] {
        let descriptor = FetchDescriptor<MeetingSummaryEmbedding>()
        let rows = try modelContext.fetch(descriptor)
        let queryNorm = Self.l2Norm(query)
        var scored = rows.map { row in
            let v = Self.decode(row.embedding, dim: row.embeddingDim)
            return (meetingId: row.meetingId, score: Self.cosine(query, v, qNorm: queryNorm))
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(topK))
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data, dim: Int) -> [Float] {
        guard dim > 0, data.count >= dim * MemoryLayout<Float>.size else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf.prefix(dim))
        }
    }

    static func l2Norm(_ v: [Float]) -> Float {
        var s: Float = 0
        for x in v { s += x * x }
        return sqrtf(s)
    }

    static func cosine(_ a: [Float], _ b: [Float], qNorm: Float) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0
        var bNorm: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            bNorm += b[i] * b[i]
        }
        let denom = qNorm * sqrtf(bNorm)
        return denom > 0 ? dot / denom : 0
    }
}
