import XCTest
@testable import Aftertalk

/// Tests for `QuestionNormalizer`. Focused on two things: the narrow whitelist
/// rewrites the proper nouns we care about, and equally important, the
/// normalizer **refuses** to rewrite common words even when they look like
/// they could be ASR mishearings. The May 1 device test caught Codex pushing
/// back on overly aggressive normalization ("music" → "meetings", "the times"
/// → "times") and these tests are the regression line for that pushback.
final class QuestionNormalizerTests: XCTestCase {

    // MARK: - Project-specific proper nouns DO get normalized

    func testAftertalkVariantsCollapseToCanonicalForm() {
        XCTAssertEqual(
            QuestionNormalizer.normalize("Tell me about afterthoughts."),
            "Tell me about Aftertalk."
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("Summarize my after talk meeting."),
            "Summarize my Aftertalk meeting."
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("What is after-talk doing well?"),
            "What is Aftertalk doing well?"
        )
        // Already canonical case stays normalized (idempotent).
        XCTAssertEqual(
            QuestionNormalizer.normalize("Aftertalk shipped today."),
            "Aftertalk shipped today."
        )
    }

    func testOpenAIIsCollapsedToOneWord() {
        XCTAssertEqual(
            QuestionNormalizer.normalize("did open ai release a new model"),
            "did OpenAI release a new model"
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("OpenAI shipped Codex"),
            "OpenAI shipped Codex"
        )
    }

    func testStackTokensGetCanonicalCasing() {
        XCTAssertEqual(
            QuestionNormalizer.normalize("how does bm25 compare to rrf"),
            "how does BM25 compare to RRF"
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("explain the rag pipeline"),
            "explain the RAG pipeline"
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("when does kokoro warm up"),
            "when does Kokoro warm up"
        )
    }

    // MARK: - Common words DO NOT get normalized

    func testCommonWordsAreLeftAlone() {
        // The May 1 device log captured "music" mistranscribed for "meetings"
        // and "Times" mistranscribed for "times". Both could legitimately be
        // real meeting content. The normalizer must NOT silently rewrite them.
        XCTAssertEqual(
            QuestionNormalizer.normalize("Did anyone discuss music in the studio?"),
            "Did anyone discuss music in the studio?"
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("How many times was the New York Times mentioned?"),
            "How many times was the New York Times mentioned?"
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("Which meeting was longest?"),
            "Which meeting was longest?"
        )
    }

    func testNoRewriteOnPartialMatchInsideLargerWord() {
        // The word-boundary anchor must prevent "afterthoughts" inside a
        // longer compound from triggering. Catching a real word that happens
        // to start with the same letters would be a worse failure than the
        // original mistranscription.
        XCTAssertEqual(
            QuestionNormalizer.normalize("the codexification of work"),
            "the codexification of work"
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("ragged edges in the audio"),
            "ragged edges in the audio"
        )
    }

    // MARK: - Behavior on edge cases

    func testEmptyAndWhitespaceInputsAreReturnedUnchanged() {
        XCTAssertEqual(QuestionNormalizer.normalize(""), "")
        XCTAssertEqual(QuestionNormalizer.normalize("   "), "   ")
    }

    func testNoMatchIsByteForByteIdentical() {
        // When the normalizer makes no substitution, the output must match
        // the input exactly so callers can compare in==out to detect a no-op.
        let input = "Was the budget approved last quarter?"
        XCTAssertEqual(QuestionNormalizer.normalize(input), input)
    }

    func testPunctuationAroundProperNounsIsPreserved() {
        XCTAssertEqual(
            QuestionNormalizer.normalize(#"What did "afterthoughts" actually mean?"#),
            #"What did "Aftertalk" actually mean?"#
        )
        XCTAssertEqual(
            QuestionNormalizer.normalize("Tell me about afterthoughts, please."),
            "Tell me about Aftertalk, please."
        )
    }
}
