import XCTest
@testable import Aftertalk

/// Pure-logic tests for `SentenceBoundaryDetector`. The detector is fed the
/// full snapshot text on each call (Foundation Models snapshot streaming),
/// emits newly-finalized sentences when it sees a terminator + whitespace,
/// and emits any trailing fragment via `finalize`.
///
/// These tests exercise the invariants the streaming TTS relies on:
///   - sentences are never duplicated across feeds
///   - a long sentence still gets soft-wrapped at the limit so the synth
///     queue doesn't stall waiting for a period that never comes
///   - trailing text without a terminator is recovered by `finalize`
final class SentenceBoundaryDetectorTests: XCTestCase {

    func testEmitsSentenceOnTerminatorPlusSpace() {
        var d = SentenceBoundaryDetector()
        let s = d.feed("Hello world. ")
        XCTAssertEqual(s, ["Hello world."])
    }

    func testRequiresWhitespaceLookaheadMidStream() {
        var d = SentenceBoundaryDetector()
        // Mid-stream period followed by a non-whitespace character (e.g. a
        // version number "v1.0X" or "Q3.X" while the model is still
        // streaming) must not be treated as a sentence boundary. The
        // detector waits for a whitespace lookahead so abbreviations and
        // numeric tokens don't trigger premature emission.
        XCTAssertEqual(d.feed("Hello.X"), [])
        // Once the snapshot extends and shows a real boundary, the
        // sentence finalizes correctly.
        XCTAssertEqual(d.feed("Hello.X is wrong. "), ["Hello.X is wrong."])
    }

    func testIncrementalFeedDoesNotDuplicateSentences() {
        var d = SentenceBoundaryDetector()
        // Streaming snapshot pattern: each call carries the full text seen
        // so far. Detector must only emit *new* sentences on each call.
        let s1 = d.feed("First. ")
        XCTAssertEqual(s1, ["First."])
        let s2 = d.feed("First. Second. ")
        XCTAssertEqual(s2, ["Second."])
        let s3 = d.feed("First. Second. Third. ")
        XCTAssertEqual(s3, ["Third."])
    }

    func testFinalizeReturnsTrailingFragment() {
        var d = SentenceBoundaryDetector()
        _ = d.feed("Final answer")  // no terminator
        let tail = d.finalize("Final answer")
        XCTAssertEqual(tail, ["Final answer"])
    }

    func testFinalizeAfterCompletedSentenceReturnsEmpty() {
        var d = SentenceBoundaryDetector()
        _ = d.feed("Done. ")
        let tail = d.finalize("Done. ")
        XCTAssertTrue(tail.isEmpty, "If everything was already emitted, finalize has nothing to add")
    }

    func testQuestionAndExclamationAreTerminators() {
        var d = SentenceBoundaryDetector()
        XCTAssertEqual(d.feed("Why? "), ["Why?"])
        var d2 = SentenceBoundaryDetector()
        XCTAssertEqual(d2.feed("Stop! "), ["Stop!"])
    }

    func testSoftWrapKicksInOnLongRunWithoutTerminator() {
        var d = SentenceBoundaryDetector()
        // Build a 200-character "sentence" of single-word tokens with no
        // period. Default soft-wrap limit is 130; the detector must split
        // at the next whitespace past 130 chars instead of stalling.
        let words = Array(repeating: "word", count: 60).joined(separator: " ")
        let sentences = d.feed(words + " ")
        XCTAssertGreaterThanOrEqual(
            sentences.count,
            1,
            "Soft-wrap must emit at least one fragment before finalize on long terminator-less runs"
        )
    }
}
