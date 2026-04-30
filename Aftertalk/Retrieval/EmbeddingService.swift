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
/// language asset hasn't been downloaded yet. **Throws on every embed
/// call** so the pipeline can detect the degraded state per-row and
/// persist the chunk/summary with `embeddingDim = 0` instead of saving
/// dummy zero vectors.
///
/// Why throwing instead of returning zeros (the previous design):
///   - Reviewer flagged that persisted zero embeddings poison future
///     retrieval. If NLContextual recovers later, those chunks remain
///     semantically dead unless explicitly re-embedded — but the storage
///     layer can't tell "0-dim placeholder" from "real but empty"
///     without an out-of-band marker.
///   - Throwing makes the failure explicit at the call site. The
///     pipeline now tolerates per-row failures (chunks are saved with
///     dim = 0 and skipped at retrieval time) instead of saving
///     dim = 8 placeholders that confuse the cosine path.
///
/// The repair flow (re-embed dim=0 rows once NLContextual recovers) is
/// documented in the README "what I'd build with another two weeks"
/// section.
final class NoOpEmbeddingService: EmbeddingService, @unchecked Sendable {
    /// Dimension is reported as 0 to match the dim of stored degraded
    /// rows. Any caller asking the dim before calling embed gets a
    /// truthful "I don't have a working model" signal.
    let dimension: Int = 0

    func embed(_ text: String) async throws -> [Float] {
        throw EmbeddingError.modelUnavailable
    }
}
