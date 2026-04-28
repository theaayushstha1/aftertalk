import Foundation

/// Streaming sentence detector used by the Q&A pipeline.
///
/// Foundation Models emits `MeetingSummary.PartiallyGenerated` snapshots that
/// grow the answer text monotonically. The detector keeps a cursor over the
/// last-emitted boundary so each call to `feed(_:)` only returns sentences that
/// completed since the previous call. A long sentence with no terminator gets
/// force-cut at `softWrapLimit` so TTS keeps a steady cadence.
///
/// Pure logic, no audio. Unit-testable.
struct SentenceBoundaryDetector {
    // Soft-wrap is a safety valve for runaway phrases the LLM never punctuates.
    // Two competing constraints set this knob:
    //   - Too low (e.g. 80) chops natural sentences into 3-4 fragments and
    //     introduces a prosody attack + ~80 ms tail silence per chunk, making
    //     the answer sound stuttered.
    //   - Too high routes long sentences to FluidAudio's Kokoro 15s graph,
    //     which we no longer load (see `KokoroTTSService.performWarmInternal` —
    //     loading both 5s + 15s graphs OOMed mid-answer with jetsam code 9).
    // The 5s graph handles roughly ~140 phoneme IDs reliably; English averages
    // ~1.5 phonemes per character, so 130 chars sits in a safe zone where it
    // (a) only fires on long compound sentences that would clip 5s anyway,
    // (b) keeps natural-length sentences intact, and
    // (c) never trips a 15s graph load.
    var softWrapLimit: Int = 130
    private(set) var cursor: String.Index?

    /// Feed the entire snapshot text (not the delta). Returns the new sentences
    /// that have completed since the last feed.
    mutating func feed(_ text: String) -> [String] {
        let scanStart = cursor ?? text.startIndex
        guard scanStart < text.endIndex else {
            cursor = text.endIndex
            return []
        }

        var emitted: [String] = []
        var lastBoundary = scanStart
        var i = scanStart
        var charsSinceBoundary = 0

        while i < text.endIndex {
            let ch = text[i]
            let next = text.index(after: i)
            let nextChar = next < text.endIndex ? text[next] : nil

            let isTerminator = ch == "." || ch == "!" || ch == "?"
            let lookaheadIsBreak = nextChar.map { $0.isWhitespace } ?? true

            if isTerminator && lookaheadIsBreak {
                let sentence = String(text[lastBoundary...i])
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { emitted.append(trimmed) }
                lastBoundary = next
                i = next
                charsSinceBoundary = 0
                continue
            }

            charsSinceBoundary += 1
            // Soft-wrap at the next whitespace once we cross the limit so we
            // don't split a word in half.
            if charsSinceBoundary >= softWrapLimit && ch.isWhitespace {
                let sentence = String(text[lastBoundary...i])
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { emitted.append(trimmed) }
                lastBoundary = text.index(after: i)
                charsSinceBoundary = 0
            }
            i = next
        }

        cursor = lastBoundary
        return emitted
    }

    /// Call when the upstream stream finishes. Emits any trailing fragment.
    mutating func finalize(_ text: String) -> [String] {
        let from = cursor ?? text.startIndex
        defer { cursor = text.endIndex }
        guard from < text.endIndex else { return [] }
        let tail = String(text[from..<text.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? [] : [tail]
    }
}
