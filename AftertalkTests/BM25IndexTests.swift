import XCTest
@testable import Aftertalk

/// Pure-logic tests for `BM25Index` tokenization. The end-to-end search
/// path requires a SwiftData ModelContainer with seeded chunks, which
/// we don't bring up here — that's covered indirectly by the
/// HierarchicalRetriever device path. These tests cover the
/// preprocessing invariants every BM25 query depends on:
///   - Lowercasing
///   - Punctuation/symbol splits
///   - Stopword filtering
///   - Length floor (no single-character tokens)
final class BM25IndexTests: XCTestCase {

    func testTokenizeLowercasesAndSplitsOnPunctuation() {
        let tokens = BM25Index.tokenize("Hello, World! How's the H100?")
        // "Hello", "World", "How", "s", "the", "H100"
        // After stopword + length filter: drops "s" (length<2), "the".
        XCTAssertTrue(tokens.contains("hello"))
        XCTAssertTrue(tokens.contains("world"))
        XCTAssertTrue(tokens.contains("h100"))
        XCTAssertFalse(tokens.contains("Hello"), "Tokens must be lowercased")
        XCTAssertFalse(tokens.contains("the"), "Stopword 'the' must be dropped")
    }

    func testTokenizeDropsStopwords() {
        let tokens = BM25Index.tokenize("the and or but of")
        XCTAssertTrue(tokens.isEmpty, "All-stopword input must produce no tokens")
    }

    func testTokenizeDropsShortTokens() {
        let tokens = BM25Index.tokenize("a I we to in")
        // "we" is intentionally NOT a stopword (matters for who-said-what)
        // "to" / "in" / "a" / "i" are stopwords or length<2.
        XCTAssertEqual(tokens, ["we"])
    }

    func testTokenizePreservesProperNounsAndIdentifiers() {
        let tokens = BM25Index.tokenize("Jensen mentioned the H100 and B200 chips")
        XCTAssertTrue(tokens.contains("jensen"))
        XCTAssertTrue(tokens.contains("h100"))
        XCTAssertTrue(tokens.contains("b200"))
        XCTAssertTrue(tokens.contains("chips"))
        XCTAssertFalse(tokens.contains("the"))
        XCTAssertFalse(tokens.contains("and"))
    }

    func testTokenizeHandlesMixedAlphanumericAndUnicode() {
        // Unicode letters get folded by `Character.isLetter` (true for
        // accented Latin). Numbers stay. Symbols split.
        let tokens = BM25Index.tokenize("Q3-2026 review: action items")
        XCTAssertTrue(tokens.contains("q3"))
        XCTAssertTrue(tokens.contains("2026"))
        XCTAssertTrue(tokens.contains("review"))
        XCTAssertTrue(tokens.contains("action"))
        XCTAssertTrue(tokens.contains("items"))
    }
}
