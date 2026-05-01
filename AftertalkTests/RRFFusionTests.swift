import XCTest
import SwiftData
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

final class GlobalAskRouterTests: XCTestCase {
    private func headers(_ count: Int, withSummaries: Bool = false) -> [MeetingHeader] {
        (0..<count).map { index in
            MeetingHeader(
                id: UUID(),
                title: "Meeting \(index + 1)",
                recordedAt: Date(timeIntervalSince1970: Double(index)),
                summary: withSummaries
                    ? MeetingHeader.SummarySnapshot(
                        decisions: index == 0 ? ["Ship the local prototype."] : [],
                        topics: index.isMultiple(of: 2)
                            ? ["AI product review", "Private transcription"]
                            : ["Interview prep", "RAG quality"],
                        actionItems: [],
                        openQuestions: []
                    )
                    : nil
            )
        }
    }

    func testMetadataRouterDoesNotStealMentionCountQuestion() {
        let answer = QAOrchestrator.answerMetadataQuestion(
            "How many times was AI mentioned across the meeting?",
            headers: headers(40)
        )
        XCTAssertNil(answer)
    }

    func testMetadataRouterDoesNotStealContentCountQuestion() {
        let answer = QAOrchestrator.answerMetadataQuestion(
            "How many meetings talked about AI productivity and model quality?",
            headers: headers(5)
        )
        XCTAssertNil(answer)
    }

    func testMetadataRouterStillAnswersMeetingCount() {
        let answer = QAOrchestrator.answerMetadataQuestion(
            "How many meetings do I have?",
            headers: headers(2)
        )
        XCTAssertEqual(answer, "You have 2 meetings recorded.")
    }

    func testExtractMentionCountTermHandlesAiWordQuestion() {
        let term = QAOrchestrator.extractMentionCountTerm(
            "How many times has the AI word been mentioned across the meeting?"
        )
        XCTAssertEqual(term, "ai")
    }

    func testSpeechTextForTTSRemovesQuoteArtifacts() {
        let spoken = QAOrchestrator.speechTextForTTS(
            #"In "Model performance and user adoption" AI is discussed in "AI productivity improvements" and "open AI.""#
        )
        XCTAssertEqual(
            spoken,
            "In Model performance and user adoption AI is discussed in AI productivity improvements and open AI."
        )
    }

    func testSpeechTextForTTSMergesLeadingTinyFragment() {
        let spoken = QAOrchestrator.speechTextForTTS(
            "coding. They discussed the subjective nature of model breakthroughs."
        )
        XCTAssertEqual(
            spoken,
            "coding, and they discussed the subjective nature of model breakthroughs."
        )
    }

    func testSpeechTextForTTSDropsOrphanFunctionWord() {
        XCTAssertEqual(QAOrchestrator.speechTextForTTS("In"), "")
    }

    func testSpeechTextForTTSPreservesContractionsAndPossessives() {
        // Apostrophes inside words must survive — Kokoro is a graphemic-input
        // model and "dont", "Andres", "well" (from "we'll") all degrade
        // pronunciation if the apostrophe is stripped indiscriminately.
        XCTAssertEqual(
            QAOrchestrator.speechTextForTTS("Andre's plan was that we'll do it, but he doesn't agree."),
            "Andre's plan was that we'll do it, but he doesn't agree."
        )
    }

    func testSpeechTextForTTSStillStripsFlankingQuotes() {
        // Quotes that flank whitespace or punctuation are still stripped —
        // the original artifact pattern from Kokoro's awkward chunking.
        XCTAssertEqual(
            QAOrchestrator.speechTextForTTS(#"In "open AI" the model said it doesn't matter."#),
            "In open AI the model said it doesn't matter."
        )
    }

    func testMetadataRouterAnswerSanitizesForSpeech() {
        // Regression: the deterministic metadata router used to return
        // `Your most recent meeting is "Foo".` with literal quotes around the
        // title, and `speakImmediateGlobalAnswer` then handed that raw text
        // to Kokoro. The chunker split it into `In"` / `is" Foo"` artifacts.
        // The fix routes router answers through `speechTextForTTS` before
        // playback. Verify the sanitizer does the right thing on the exact
        // shape the router produces.
        let routerAnswer = #"Your most recent meeting is "Class · Something"."#
        let spoken = QAOrchestrator.speechTextForTTS(routerAnswer)
        XCTAssertEqual(spoken, "Your most recent meeting is Class · Something.")
    }

    func testMentionCountAnswerAggregatesAcrossMeetings() {
        let counts = [
            MeetingMentionCount(meetingId: UUID(), title: "Research Sync", count: 4),
            MeetingMentionCount(meetingId: UUID(), title: "Design Review", count: 2),
        ]
        let answer = QAOrchestrator.answerMentionCount(term: "ai", counts: counts, totalMeetings: 5)
        XCTAssertTrue(answer.contains("AI was mentioned 6 times"))
        XCTAssertTrue(answer.contains("across 2 meetings, out of 5 meetings"))
    }

    func testMentionCountsScanFullTranscriptsWithAiVariants() async throws {
        let config = ModelConfiguration(
            "MentionCountsTest",
            schema: AftertalkPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: AftertalkPersistence.schema, configurations: [config])
        let repository = MeetingsRepository(modelContainer: container)
        _ = try await repository.createMeeting(
            title: "AI Sync",
            transcript: "AI came up first. Then A.I. came up again. Finally A I was said.",
            duration: 10
        )

        let counts = try await repository.mentionCounts(for: "ai")

        XCTAssertEqual(counts.first?.count, 3)
    }

    func testGlobalOverviewQuestionUsesAllSummaries() {
        let answer = QAOrchestrator.answerGlobalOverviewQuestion(
            "What kind of thing did this meeting talk about?",
            headers: headers(4, withSummaries: true)
        )
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer?.contains("Across your 4 meetings") == true)
        XCTAssertTrue(answer?.contains("AI product review") == true)
        XCTAssertTrue(answer?.contains("RAG quality") == true)
    }
}
