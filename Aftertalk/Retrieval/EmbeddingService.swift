import Foundation
import NaturalLanguage

protocol EmbeddingService: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

enum EmbeddingError: Error, CustomStringConvertible {
    case modelUnavailable
    case empty
    case dimensionMismatch(expected: Int, got: Int)

    var description: String {
        switch self {
        case .modelUnavailable: "Embedding model unavailable for current language."
        case .empty: "Empty input."
        case .dimensionMismatch(let e, let g): "Embedding dim mismatch: expected \(e), got \(g)."
        }
    }
}

/// Apple's NLContextualEmbedding. ~512-dim, free, on-device, no model bundle.
/// Swap to gte-small Core ML by implementing EmbeddingService against MLModel.
final class NLContextualEmbeddingService: EmbeddingService, @unchecked Sendable {
    let dimension: Int
    private let embedding: NLContextualEmbedding

    init(language: NLLanguage = .english) throws {
        guard let emb = NLContextualEmbedding(language: language) else {
            throw EmbeddingError.modelUnavailable
        }
        if !emb.hasAvailableAssets {
            emb.requestAssets { _, _ in }
        }
        try emb.load()
        self.embedding = emb
        self.dimension = emb.dimension
    }

    func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.empty }
        let result = try embedding.embeddingResult(for: trimmed, language: nil)
        var sum = [Float](repeating: 0, count: dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for i in 0..<min(self.dimension, vector.count) {
                sum[i] += Float(vector[i])
            }
            tokenCount += 1
            return true
        }
        guard tokenCount > 0 else { throw EmbeddingError.empty }
        let inv = 1.0 / Float(tokenCount)
        for i in 0..<dimension { sum[i] *= inv }
        return l2Normalize(sum)
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = sqrtf(norm)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}

/// No-op embedding fallback for when `NLContextualEmbedding` can't load on
/// this device — typically a fresh airplane-mode iPhone whose system
/// language asset hasn't been downloaded yet. Returns a fixed zero vector
/// so chunks + summaries still persist (the rest of the pipeline doesn't
/// have to special-case nil), but cosine similarity against zero vectors
/// is degenerate so retrieval will return no hits and the grounding gate
/// will fire. The chat surfaces gate themselves on
/// `QAContext.semanticQAAvailable` and show a "Semantic Q&A unavailable"
/// banner, so users see a clear explanation instead of confusing
/// disclaimers from the orchestrator.
final class NoOpEmbeddingService: EmbeddingService, @unchecked Sendable {
    /// 8 floats is enough to keep persistence happy and small enough that
    /// every saved chunk's storage overhead is negligible. The dimension
    /// is intentionally not 512 — anyone reading SwiftData later can tell
    /// from the size that this row was written in degraded mode.
    let dimension: Int = 8

    func embed(_ text: String) async throws -> [Float] {
        return [Float](repeating: 0, count: dimension)
    }
}
