import XCTest
@testable import Aftertalk

/// Pure-logic tests for `HierarchicalRetriever.fuseRRF`. The fusion
/// function is the keystone of the hybrid retrieval claim — if it
/// silently drops BM25-only hits or mis-ranks the combined list, the
/// "BM25 catches keyword precision" promise is empty.
///
/// These tests cover the invariants:
///   1. Both lists hydrated → BM25-only hits survive
///   2. Dense-only path (legacy / fallback) returns dense ordering
///   3. Empty inputs are handled gracefully
///   4. Higher-ranked hits in either source bubble up under RRF
final class RRFFusionTests: XCTestCase {

    private func hit(_ id: UUID, score: Float, order: Int = 0) -> ChunkHit {
        ChunkHit(
            chunkId: id,
            meetingId: UUID(),
            text: "chunk \(order)",
            startSec: 0,
            endSec: 1,
            speakerName: nil,
            score: score,
            orderIndex: order
        )
    }

    func testBM25OnlyHitSurvivesFusion() {
        // Reviewer's P1 case. Three dense hits, none of which is the
        // BM25-top hit; BM25 finds chunk D as #1 (e.g. exact keyword
        // match) but dense never sees it. Fused topK=4 must include D.
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let dense = [
            hit(a, score: 0.5, order: 1),
            hit(b, score: 0.4, order: 2),
            hit(c, score: 0.3, order: 3),
        ]
        let bm25 = [
            hit(d, score: 9.5, order: 4),  // BM25-only — must not be dropped
            hit(a, score: 1.2, order: 1),  // overlaps with dense
        ]
        let fused = HierarchicalRetriever.fuseRRF(dense: dense, bm25: bm25, topK: 4)
        let fusedIds = Set(fused.map(\.chunkId))
        XCTAssertTrue(fusedIds.contains(d), "BM25-only hit must survive fusion (P1 reviewer ask)")
        XCTAssertEqual(fused.count, 4, "All 4 unique chunks fit in topK=4")
    }

    func testDenseOnlyInputPreservesOrdering() {
        // No BM25 input (legacy path / BM25 service unavailable). Fused
        // result should be dense in dense's original order.
        let a = UUID(), b = UUID(), c = UUID()
        let dense = [
            hit(a, score: 0.9, order: 1),
            hit(b, score: 0.5, order: 2),
            hit(c, score: 0.2, order: 3),
        ]
        let fused = HierarchicalRetriever.fuseRRF(dense: dense, bm25: [], topK: 3)
        XCTAssertEqual(fused.map(\.chunkId), [a, b, c], "Dense-only input preserves order")
    }

    func testBothListsEmptyReturnsEmpty() {
        let fused = HierarchicalRetriever.fuseRRF(dense: [], bm25: [], topK: 5)
        XCTAssertTrue(fused.isEmpty)
    }

    func testCommonHitGetsBoostedByBothSources() {
        // Chunk that's #1 in dense AND #1 in BM25 should outrank
        // chunks that appeared in only one source — RRF sums the
        // reciprocal ranks. Validates the actual fusion math, not
        // just survivorship.
        let common = UUID()
        let denseOnly = UUID()
        let bm25Only = UUID()
        let dense = [
            hit(common, score: 0.5, order: 1),
            hit(denseOnly, score: 0.4, order: 2),
        ]
        let bm25 = [
            hit(common, score: 5.0, order: 1),
            hit(bm25Only, score: 4.0, order: 2),
        ]
        let fused = HierarchicalRetriever.fuseRRF(dense: dense, bm25: bm25, topK: 3)
        XCTAssertEqual(fused.first?.chunkId, common, "Common hit should rank #1 (sum of reciprocal ranks)")
    }

    func testCommonHitKeepsDenseScore() {
        // Grounding gate is tuned against cosine; when both sources find
        // the same chunk, the fused result must carry the dense (cosine)
        // score, not the BM25 score (different scale).
        let id = UUID()
        let dense = [hit(id, score: 0.65, order: 1)]
        let bm25 = [hit(id, score: 9.3, order: 1)]
        let fused = HierarchicalRetriever.fuseRRF(dense: dense, bm25: bm25, topK: 1)
        XCTAssertEqual(fused.first?.score ?? 0, Float(0.65), accuracy: Float(0.001),
                       "Common hit keeps dense cosine — gate is tuned against it")
    }
}
