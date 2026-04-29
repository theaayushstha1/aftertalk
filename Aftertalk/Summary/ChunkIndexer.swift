import Foundation
import NaturalLanguage

struct ChunkDraft: Sendable {
    let orderIndex: Int
    let text: String
    let startSec: Double
    let endSec: Double
    let speakerName: String?
    /// Stable Pyannote speaker id ("Speaker_1" …) reconciled from word
    /// timings. `nil` when diarization didn't run or no overlap was found.
    let speakerId: String?

    init(
        orderIndex: Int,
        text: String,
        startSec: Double,
        endSec: Double,
        speakerName: String? = nil,
        speakerId: String? = nil
    ) {
        self.orderIndex = orderIndex
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.speakerName = speakerName
        self.speakerId = speakerId
    }
}

/// Splits a transcript into sentence windows (max 4 sentences) and produces
/// one ChunkDraft per window. When timestamped speaker turns aren't available
/// (Day 2 has no diarization yet), startSec/endSec are estimated from cumulative
/// character-rate against total duration.
struct ChunkIndexer {
    var maxSentencesPerChunk: Int = 4
    var minSentencesPerChunk: Int = 1
    var sentenceOverlap: Int = 1

    func chunks(from transcript: String, durationSeconds: Double) -> [ChunkDraft] {
        let sentences = Self.splitSentences(transcript)
        guard !sentences.isEmpty else { return [] }
        let totalChars = max(1, sentences.reduce(0) { $0 + $1.count })
        var charsBefore = 0
        var startCharsBySentence: [Int] = []
        startCharsBySentence.reserveCapacity(sentences.count)
        for s in sentences {
            startCharsBySentence.append(charsBefore)
            charsBefore += s.count
        }

        var drafts: [ChunkDraft] = []
        var i = 0
        var orderIndex = 0
        while i < sentences.count {
            let end = min(i + maxSentencesPerChunk, sentences.count)
            // After the first chunk, skip windows whose only content is the
            // overlap from the previous chunk — otherwise a transcript whose
            // length lands on an advance boundary emits a redundant tail
            // chunk consisting of just the overlap sentence.
            if i > 0 && (end - i) <= sentenceOverlap { break }
            let window = Array(sentences[i..<end])
            let text = window.joined(separator: " ")
            let startChar = startCharsBySentence[i]
            let endSentenceIdx = end - 1
            let endChar = startCharsBySentence[endSentenceIdx] + sentences[endSentenceIdx].count
            let startSec = Double(startChar) / Double(totalChars) * durationSeconds
            let endSec = Double(endChar) / Double(totalChars) * durationSeconds
            drafts.append(ChunkDraft(
                orderIndex: orderIndex,
                text: text,
                startSec: startSec,
                endSec: endSec,
                speakerName: nil
            ))
            orderIndex += 1
            let advance = max(minSentencesPerChunk, maxSentencesPerChunk - sentenceOverlap)
            i += advance
        }
        return drafts
    }

    /// Stamp each chunk with its dominant speakerId based on word-level
    /// assignments. Returns a new array; never mutates the caller's drafts.
    /// If `assignments` is empty (diarization didn't run) returns `drafts`
    /// unchanged.
    ///
    /// Used only on the no-word-timing fallback path. When we *do* have word
    /// timings, prefer `chunksFromWordAssignments(_:)` which splits at speaker
    /// boundaries instead of flattening multi-turn windows to one label.
    func stampSpeakers(
        on drafts: [ChunkDraft],
        words: [WordSpeakerAssignment]
    ) -> [ChunkDraft] {
        guard !words.isEmpty else { return drafts }
        return drafts.map { d in
            let sid = DiarizationReconciler.dominantSpeaker(
                for: d.startSec,
                chunkEnd: d.endSec,
                words: words
            )
            return ChunkDraft(
                orderIndex: d.orderIndex,
                text: d.text,
                startSec: d.startSec,
                endSec: d.endSec,
                speakerName: d.speakerName,
                speakerId: sid
            )
        }
    }

    /// Speaker-turn-aware chunking. Walks per-word speaker assignments and
    /// emits one chunk per contiguous same-speaker run, using *real* word
    /// timings instead of character-rate estimates. Long single-speaker
    /// turns are further split into ≤`maxSentencesPerChunk` sentence windows
    /// so retrieval stays well-scoped.
    ///
    /// **Why this exists**: `chunks(from:durationSeconds:)` bins by sentence
    /// count and time-estimates from char ratios. With diarized audio that's
    /// wrong on two axes — (a) a 4-sentence window can span a speaker
    /// turnover, and (b) `dominantSpeaker` then collapses that mixed window
    /// to whichever voice happened to talk most. The transcript view ends up
    /// labeling Sara/Mark back-and-forth as one Speaker. This API resolves
    /// both: chunk boundaries follow speaker turnover boundaries, and
    /// `speakerId` is exact, not majority-voted.
    ///
    /// Words with `nil` speakerId (silence / no segment overlap) are folded
    /// into the previous speaker's turn so trailing punctuation tokens don't
    /// emit a phantom "unknown" chunk between two same-speaker turns.
    func chunksFromWordAssignments(_ words: [WordSpeakerAssignment]) -> [ChunkDraft] {
        guard !words.isEmpty else { return [] }

        // Step 1 — group consecutive same-speaker words into turns. Treat
        // `nil` words as belonging to the running turn so a brief silence
        // mid-utterance doesn't fragment the speaker run.
        struct Turn {
            var speakerId: String?
            var words: [WordSpeakerAssignment]
        }
        var turns: [Turn] = []
        var current: Turn? = nil
        for w in words {
            if let cur = current {
                let sameSpeaker = (w.speakerId == nil) || (w.speakerId == cur.speakerId)
                if sameSpeaker {
                    current?.words.append(w)
                    // Promote nil → real id when the first labeled word arrives.
                    if current?.speakerId == nil, let sid = w.speakerId {
                        current?.speakerId = sid
                    }
                } else {
                    turns.append(cur)
                    current = Turn(speakerId: w.speakerId, words: [w])
                }
            } else {
                current = Turn(speakerId: w.speakerId, words: [w])
            }
        }
        if let last = current { turns.append(last) }

        // Step 2 — render each turn into one or more ChunkDrafts. Short turns
        // become a single draft. Long turns get sub-windowed by sentence
        // count so embedding/retrieval doesn't see an 800-word monologue
        // chunk. Sub-window timings are interpolated by character ratio
        // *within* the turn, which is fine — the speakerId is invariant.
        var drafts: [ChunkDraft] = []
        var orderIndex = 0
        for turn in turns {
            let text = Self.detokenize(turn.words.map(\.text))
            guard !text.isEmpty else { continue }
            let turnStart = turn.words.first?.startSec ?? 0
            let turnEnd = turn.words.last?.endSec ?? turnStart

            let sentences = Self.splitSentences(text)
            if sentences.count <= maxSentencesPerChunk {
                drafts.append(ChunkDraft(
                    orderIndex: orderIndex,
                    text: text,
                    startSec: turnStart,
                    endSec: turnEnd,
                    speakerName: nil,
                    speakerId: turn.speakerId
                ))
                orderIndex += 1
                continue
            }

            let totalChars = max(1, sentences.reduce(0) { $0 + $1.count })
            var sentStarts: [Int] = []
            var acc = 0
            for s in sentences {
                sentStarts.append(acc)
                acc += s.count
            }
            let turnDur = max(0, turnEnd - turnStart)
            var i = 0
            while i < sentences.count {
                let end = min(i + maxSentencesPerChunk, sentences.count)
                if i > 0 && (end - i) <= sentenceOverlap { break }
                let window = Array(sentences[i..<end])
                let windowText = window.joined(separator: " ")
                let startChar = sentStarts[i]
                let endChar = sentStarts[end - 1] + sentences[end - 1].count
                let startSec = turnStart + Double(startChar) / Double(totalChars) * turnDur
                let endSec = turnStart + Double(endChar) / Double(totalChars) * turnDur
                drafts.append(ChunkDraft(
                    orderIndex: orderIndex,
                    text: windowText,
                    startSec: startSec,
                    endSec: endSec,
                    speakerName: nil,
                    speakerId: turn.speakerId
                ))
                orderIndex += 1
                let advance = max(minSentencesPerChunk, maxSentencesPerChunk - sentenceOverlap)
                i += advance
            }
        }
        return drafts
    }

    /// Reassemble Parakeet TDT SentencePiece subword tokens into readable
    /// text. Tokens that start a new word carry a `▁` (U+2581) prefix or a
    /// leading space; tokens that continue a word ("don" after "Par") carry
    /// neither. Joining with `" "` produces "▁Par don" — a literal block
    /// glyph plus a phantom mid-word space. Strip the marker and concatenate
    /// without inserting whitespace.
    static func detokenize(_ tokens: [String]) -> String {
        var out = ""
        for raw in tokens {
            if raw.isEmpty { continue }
            if raw.hasPrefix("▁") {
                if !out.isEmpty { out.append(" ") }
                out.append(String(raw.dropFirst()))
            } else if raw.hasPrefix(" ") {
                if !out.isEmpty { out.append(" ") }
                out.append(contentsOf: raw.drop(while: { $0 == " " }))
            } else {
                out.append(raw)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func splitSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let s = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        return sentences
    }
}
