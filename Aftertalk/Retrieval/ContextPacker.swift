import Foundation
import FoundationModels

struct PackedContext: Sendable {
    let prompt: String
    let citations: [ChunkCitation]
    let estimatedTokens: Int
    let usedAllChunks: Bool
}

/// Packs retrieved chunks into a Foundation Models prompt budget.
///
/// Foundation Models on iOS 26 caps at 4096 tokens (input + output combined).
/// Our budget split: ~250 system + ~50 question + ≤2400 context + ~1200 generation.
/// We hard-cap context at 2400 tokens; chunks past the limit are dropped.
struct ContextPacker {
    var maxContextTokens: Int = 2400
    /// Approximate tokens-per-character for English Foundation Models tokenizer.
    /// ~4 chars per token is the conventional heuristic. Used as fallback when
    /// `Session.tokenCount(_:)` is unavailable.
    var charsPerTokenFallback: Double = 4.0

    func pack(meetingTitle: String, chunks: [ChunkHit], session: LanguageModelSession?) -> PackedContext {
        guard !chunks.isEmpty else {
            return PackedContext(prompt: "", citations: [], estimatedTokens: 0, usedAllChunks: true)
        }

        var lines: [String] = []
        var citations: [ChunkCitation] = []
        var runningTokens = 0
        var usedAll = true

        for c in chunks {
            let line = renderChunk(c, meetingTitle: meetingTitle)
            let cost = tokenCount(line, session: session)
            if runningTokens + cost > maxContextTokens {
                usedAll = false
                break
            }
            lines.append(line)
            citations.append(ChunkCitation(
                chunkId: c.chunkId,
                meetingId: c.meetingId,
                startSec: c.startSec,
                endSec: c.endSec,
                speakerName: c.speakerName
            ))
            runningTokens += cost
        }

        return PackedContext(
            prompt: lines.joined(separator: "\n\n"),
            citations: citations,
            estimatedTokens: runningTokens,
            usedAllChunks: usedAll
        )
    }

    private func renderChunk(_ c: ChunkHit, meetingTitle: String) -> String {
        let timestamp = formatTimestamp(c.startSec)
        let speaker = c.speakerName ?? "Unknown speaker"
        let truncatedTitle = String(meetingTitle.prefix(60))
        return "[\(truncatedTitle) • \(timestamp) • \(speaker)] \(c.text)"
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func tokenCount(_ text: String, session: LanguageModelSession?) -> Int {
        // Always use the char-based heuristic for budgeting. Session.tokenCount
        // is iOS 26.4+, async, and not reachable from this synchronous packer.
        // Day 6 polish can swap to a precise pre-pass if budget tightens.
        return max(1, Int((Double(text.count) / charsPerTokenFallback).rounded(.up)))
    }
}
