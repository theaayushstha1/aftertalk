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
