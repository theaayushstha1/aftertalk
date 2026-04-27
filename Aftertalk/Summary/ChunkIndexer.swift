import Foundation
import NaturalLanguage

struct ChunkDraft: Sendable {
    let orderIndex: Int
    let text: String
    let startSec: Double
    let endSec: Double
    let speakerName: String?
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
