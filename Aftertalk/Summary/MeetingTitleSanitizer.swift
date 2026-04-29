import Foundation
import NaturalLanguage

/// Pure, synchronous, easy-to-test sanitizer that filters out the junk
/// titles the Foundation Models call (and our own transcript-fragment
/// heuristic) sometimes leaks. The pipeline calls `sanitize(_:fallbackDate:)`
/// at the persistence boundary so a bad title can never reach
/// `Meeting.title` and through to the meetings list UI.
///
/// Failure modes this guards against:
///  1. FM returns the first sentence of the transcript verbatim
///     ("yeah and uh so basically what we") instead of a noun phrase.
///  2. Empty or whitespace-only output on a 10s test recording.
///  3. A "title" that is actually a question ("So what about Q3?").
///  4. A bloated 20-word run-on that breaks list-row layout.
///
/// The sanitizer first scrubs simple defects (filler prefix, trailing
/// punctuation), then escalates to NL-tagger noun extraction, and finally
/// to a dated `Recording · Apr 29` fallback so the list always reads.
enum MeetingTitleSanitizer {
    /// Filler tokens we drop if they're the leading word — these are the
    /// dead giveaway that FM dumped the first transcript sentence into the
    /// title slot. Compared post-trim, post-lowercase, post-strip-punct.
    static let fillerLeadTokens: Set<String> = [
        "um", "uh", "uhm", "umm", "er", "erm", "ah", "hmm", "mhm",
        "yeah", "yep", "yup", "ok", "okay", "right", "alright",
        "so", "well", "like", "anyway", "anyways",
        "basically", "actually", "literally",
        "i", "i'm", "im", "we", "we're", "were",
        "and", "but", "or"
    ]

    /// Question-word leads that strongly suggest the title is actually a
    /// question pulled from the transcript ("What did you mean by that").
    static let questionLeadTokens: Set<String> = [
        "what", "where", "when", "why", "how", "who", "which", "did",
        "do", "does", "is", "are", "was", "were", "can", "could",
        "should", "would", "will"
    ]

    /// Maximum acceptable word count. The brief targets 3–7 words; we
    /// allow up to 12 before treating the title as "FM dumped a sentence."
    static let maxWords = 12

    /// Minimum acceptable word count. Single-word "Meeting" / "Discussion"
    /// reads worse than the dated fallback.
    static let minWords = 2

    /// Public entry point. Call at persistence time before assigning to
    /// `meeting.title`. `fallbackDate` is normally the meeting's
    /// `recordedAt` so the dated fallback (`Recording · Apr 29`) lines up.
    static func sanitize(_ raw: String, fallbackDate: Date) -> String {
        let cleaned = stripWrappingPunct(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if !cleaned.isEmpty, accept(cleaned) {
            return cleaned
        }
        if let nounTitle = nounPhraseTitle(from: raw), accept(nounTitle) {
            return nounTitle
        }
        return datedFallback(fallbackDate)
    }

    /// Same behaviour but with an explicit transcript source for the
    /// noun-extraction step. Use this when the raw FM title is junk but the
    /// transcript itself is rich enough to mine for a salient noun.
    static func sanitize(
        _ raw: String,
        transcript: String,
        fallbackDate: Date
    ) -> String {
        let cleaned = stripWrappingPunct(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if !cleaned.isEmpty, accept(cleaned) {
            return cleaned
        }
        if let nounTitle = nounPhraseTitle(from: transcript), accept(nounTitle) {
            return nounTitle
        }
        if let nounTitle = nounPhraseTitle(from: raw), accept(nounTitle) {
            return nounTitle
        }
        return datedFallback(fallbackDate)
    }

    // MARK: - Acceptance

    /// Decide whether a candidate title is good enough to keep. Mirrors the
    /// failure-mode list in the file header: filler lead, question lead,
    /// sentence-final punctuation, word-count out of range, looks-like-a-
    /// raw-filename.
    static func accept(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Sentence-ending punctuation in the body strongly suggests a full
        // sentence, not a noun phrase. We allow a single trailing period
        // because some users write titles like "Q3 plan." — but two
        // sentences worth of `. ! ?` means it's prose.
        let sentencePunctCount = trimmed.filter { $0 == "." || $0 == "!" || $0 == "?" }.count
        if sentencePunctCount >= 2 { return false }
        if trimmed.hasSuffix("?") { return false }
        if trimmed.hasSuffix("!") { return false }

        let words = wordTokens(trimmed)
        guard words.count >= minWords, words.count <= maxWords else { return false }

        let firstLower = words[0].lowercased()
        if fillerLeadTokens.contains(firstLower) { return false }
        if questionLeadTokens.contains(firstLower) { return false }

        // Audio filenames or UUIDs leaking through — `recording_2026-04-29` etc.
        if trimmed.range(of: #"^[a-z_\-]*\d{4}[\-_]\d"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    // MARK: - Cleanup

    /// Strip wrapping quote marks and trailing colon/comma/dash that FM
    /// occasionally adds — `"Sales pipeline review:"` becomes `Sales
    /// pipeline review`. Keeps internal punctuation intact (em-dashes,
    /// middle dots) since those are valid title separators.
    static func stripWrappingPunct(_ s: String) -> String {
        var out = s
        let wrappers: Set<Character> = ["\"", "'", "`", "“", "”", "‘", "’"]
        while let first = out.first, wrappers.contains(first) {
            out.removeFirst()
        }
        while let last = out.last, wrappers.contains(last) {
            out.removeLast()
        }
        let trailing: Set<Character> = [":", ",", ";", "-", "—"]
        while let last = out.last, trailing.contains(last) {
            out.removeLast()
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordTokens(_ s: String) -> [String] {
        s.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    // MARK: - Fallback ladder

    /// Mine the most-frequent salient noun (or the top two) from the
    /// transcript via NLTagger. Used when the raw title is unusable but the
    /// transcript still carries enough signal to name the meeting.
    static func nounPhraseTitle(from transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = trimmed
        var counts: [String: Int] = [:]

        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let range = trimmed.startIndex..<trimmed.endIndex
        tagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, tokenRange in
            guard let tag, tag == .noun else { return true }
            let token = String(trimmed[tokenRange]).lowercased()
            // Drop short / stop-noun / numeric tokens — the tagger will
            // sometimes label "thing" / "stuff" as a noun, and those make
            // worse titles than the dated fallback.
            guard token.count >= 4 else { return true }
            if stopNouns.contains(token) { return true }
            counts[token, default: 0] += 1
            return true
        }

        let ranked = counts
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .prefix(2)
            .map { $0.key.capitalized }

        guard !ranked.isEmpty else { return nil }
        return ranked.joined(separator: " · ")
    }

    /// Nouns the tagger labels confidently but that don't carry meeting
    /// signal. Anything in this set is filtered out of the noun count.
    static let stopNouns: Set<String> = [
        "thing", "things", "stuff", "kind", "sort", "way", "people",
        "person", "guy", "guys", "today", "yesterday", "tomorrow",
        "minute", "minutes", "hour", "hours", "second", "seconds",
        "meeting", "call", "talk", "chat"
    ]

    /// Final fallback when nothing usable could be extracted. Format
    /// matches the ICU short-date style ("Apr 29") so the list reads as
    /// `Recording · Apr 29` — short enough for any row width.
    static func datedFallback(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return "Recording · \(formatter.string(from: date))"
    }
}
