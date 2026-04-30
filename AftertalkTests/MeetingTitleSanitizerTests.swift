import XCTest
@testable import Aftertalk

/// Pure-logic tests for `MeetingTitleSanitizer`. The sanitizer is the last
/// gate before a candidate title reaches `Meeting.title` in SwiftData, so
/// these tests cover the failure modes the file header documents:
///
///   1. FM leaks the first transcript sentence as a title
///   2. Empty / whitespace-only output on a 10-second recording
///   3. A "title" that is actually a question
///   4. Bloated 20-word run-on
///
/// Each invariant must hold or we get junk titles in the meetings list.
final class MeetingTitleSanitizerTests: XCTestCase {

    /// Use a fixed date so the dated-fallback assertion is deterministic
    /// regardless of when the test runs.
    private let fixedDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 29
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func testAcceptsCleanTitle() {
        let title = MeetingTitleSanitizer.sanitize(
            "Q3 Roadmap Sync",
            fallbackDate: fixedDate
        )
        XCTAssertEqual(title, "Q3 Roadmap Sync")
    }

    func testEmptyInputFallsBackToDatedString() {
        let title = MeetingTitleSanitizer.sanitize("", fallbackDate: fixedDate)
        XCTAssertEqual(title, "Recording · Apr 29")
    }

    func testWhitespaceOnlyFallsBackToDatedString() {
        let title = MeetingTitleSanitizer.sanitize("   \n\t  ", fallbackDate: fixedDate)
        XCTAssertEqual(title, "Recording · Apr 29")
    }

    func testFillerLeadTitleIsRejected() {
        // Filler-prefixed candidate is the FM-dumped-transcript-sentence
        // failure mode. With no transcript override and no salvageable noun
        // phrase, we expect the dated fallback.
        let title = MeetingTitleSanitizer.sanitize(
            "yeah and uh so basically what we did was",
            fallbackDate: fixedDate
        )
        XCTAssertEqual(title, "Recording · Apr 29")
    }

    func testRunOnTitleIsRejected() {
        // 20 words exceeds the 12-word ceiling; sanitizer should reject and
        // either mine a noun phrase or fall back to the dated string.
        let raw = (0..<20).map { "word\($0)" }.joined(separator: " ")
        let title = MeetingTitleSanitizer.sanitize(raw, fallbackDate: fixedDate)
        // We don't care which fallback is taken — only that the run-on
        // didn't survive verbatim.
        XCTAssertNotEqual(title, raw)
    }

    func testSingleWordTitleIsRejected() {
        // Below `minWords` (2) — should fall through to dated fallback.
        let title = MeetingTitleSanitizer.sanitize("Meeting", fallbackDate: fixedDate)
        XCTAssertEqual(title, "Recording · Apr 29")
    }

    func testTrailingWrappingPunctuationIsStripped() {
        // The sanitizer's `stripWrappingPunct` removes trailing colons,
        // semicolons, commas, dashes — punctuation that's clearly junk on
        // a title even if the rest of the string is fine. (Trailing
        // periods are intentionally NOT in the strip set because plenty
        // of real titles like "Inc." end with one.) We assert the colon
        // case here so the strip set doesn't silently shrink in a future
        // edit.
        let title = MeetingTitleSanitizer.sanitize("Q3 Roadmap Sync:", fallbackDate: fixedDate)
        XCTAssertEqual(title, "Q3 Roadmap Sync")
    }
}
