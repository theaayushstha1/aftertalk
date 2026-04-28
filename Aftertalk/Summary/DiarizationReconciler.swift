import Foundation

/// Sendable transport for `SpeakerLabel` rows so the pipeline can hand the
/// repository (an actor) a value-type batch without crossing class boundaries.
struct SpeakerLabelDraft: Sendable {
    let speakerId: String
    let displayName: String
    let colorHex: String
    let embeddingCentroid: Data?
    let firstSeenSec: Double?
}

/// Per-word speaker assignment fed into `ChunkIndexer` so each emitted
/// `ChunkDraft` carries its dominant speakerId for retrieval / UI.
struct WordSpeakerAssignment: Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
    /// `nil` if no Pyannote segment overlaps this word's time range.
    let speakerId: String?
}

/// Reconciles Pyannote speaker segments with Parakeet word timings and emits
/// (a) the per-meeting speaker roster + (b) per-word speaker assignments.
///
/// We do this off the pipeline's main path so we can unit-test the assignment
/// logic on synthetic inputs without spinning up Core ML.
enum DiarizationReconciler {

    /// Stable palette used for the SwiftUI badge color. Cycles by speaker
    /// arrival order — first speaker → palette[0], second → palette[1], etc.
    /// Hex strings, no leading `#`.
    static let palette: [String] = [
        "4F8EF7",   // blue
        "F5A623",   // amber
        "27AE60",   // green
        "E04F5F",   // red
        "9B59B6",   // purple
        "16A2B8",   // teal
        "F2C94C",   // yellow
        "8E8E93",   // grey (overflow)
    ]

    /// Build the meeting's speaker roster from a list of segments.
    ///
    /// - The display name is "Speaker 1", "Speaker 2", … assigned in
    ///   first-seen order so the UI matches the transcript's reading order
    ///   even when Pyannote happens to label the second arriver as
    ///   "Speaker_1".
    /// - `embeddingCentroid` is the L2-normalized mean of the per-segment
    ///   256-dim WeSpeaker embeddings, packed little-endian Float32.
    static func buildSpeakerRoster(from segments: [SpeakerSegment]) -> [SpeakerLabelDraft] {
        guard !segments.isEmpty else { return [] }
        // First-seen order. We rely on segments arriving sorted by startSec
        // (FluidAudio emits them per-chunk in temporal order); sort defensively.
        let sorted = segments.sorted { $0.startSec < $1.startSec }
        var firstSeen: [String: Double] = [:]
        for seg in sorted where firstSeen[seg.speakerId] == nil {
            firstSeen[seg.speakerId] = seg.startSec
        }
        let orderedIds = firstSeen.keys.sorted { (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0) }

        // Group segments by speakerId for centroid math.
        var groups: [String: [SpeakerSegment]] = [:]
        for seg in sorted { groups[seg.speakerId, default: []].append(seg) }

        return orderedIds.enumerated().map { (i, sid) in
            let group = groups[sid] ?? []
            let centroid = meanEmbedding(group.map { $0.embedding })
            let centroidData = centroid.map { Self.encodeFloats($0) }
            let color = palette[i % palette.count]
            return SpeakerLabelDraft(
                speakerId: sid,
                displayName: "Speaker \(i + 1)",
                colorHex: color,
                embeddingCentroid: centroidData,
                firstSeenSec: firstSeen[sid]
            )
        }
    }

    /// Assign each word a speakerId by selecting the segment whose temporal
    /// span overlaps the word's midpoint the most. Words that fall in
    /// silence (no overlap) get `nil`. Returns assignments in word order.
    static func assignWords(
        words: [CanonicalTranscript.WordTiming],
        segments: [SpeakerSegment]
    ) -> [WordSpeakerAssignment] {
        guard !segments.isEmpty else {
            return words.map {
                WordSpeakerAssignment(text: $0.text, startSec: $0.startSec, endSec: $0.endSec, speakerId: nil)
            }
        }
        // segments are typically <100, words <10k for an hour-long meeting —
        // O(n*m) is fine and keeps the implementation transparent.
        let sortedSegs = segments.sorted { $0.startSec < $1.startSec }
        return words.map { w in
            let mid = (w.startSec + w.endSec) / 2.0
            var best: (sid: String, overlap: Double)? = nil
            for seg in sortedSegs {
                if seg.endSec < w.startSec { continue }
                if seg.startSec > w.endSec { break }
                let overlap = max(0, min(seg.endSec, w.endSec) - max(seg.startSec, w.startSec))
                if overlap > 0, overlap > (best?.overlap ?? -1) {
                    best = (seg.speakerId, overlap)
                }
            }
            // If no positive overlap, pick the segment whose midpoint is
            // closest to the word midpoint — beats handing the chunker
            // mid-utterance `nil`s when the segment boundary is fuzzy.
            if best == nil, let nearest = sortedSegs.min(by: {
                abs(mid - ($0.startSec + $0.endSec) / 2) < abs(mid - ($1.startSec + $1.endSec) / 2)
            }) {
                best = (nearest.speakerId, 0)
            }
            return WordSpeakerAssignment(
                text: w.text,
                startSec: w.startSec,
                endSec: w.endSec,
                speakerId: best?.sid
            )
        }
    }

    /// Pick the dominant speakerId for a chunk by total speaking time
    /// (sum of word durations per speaker). Words without a speakerId are
    /// ignored. Returns `nil` if every word in the window is unassigned.
    static func dominantSpeaker(
        for chunkStart: Double,
        chunkEnd: Double,
        words: [WordSpeakerAssignment]
    ) -> String? {
        var totals: [String: Double] = [:]
        for w in words {
            if w.endSec < chunkStart || w.startSec > chunkEnd { continue }
            guard let sid = w.speakerId else { continue }
            let dur = max(0.001, w.endSec - w.startSec)
            totals[sid, default: 0] += dur
        }
        return totals.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Math helpers

    /// Mean of N same-length [Float] vectors. Returns `nil` for empty input
    /// or ragged shapes (defensive — should never happen in practice).
    static func meanEmbedding(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let dim = first.count
        for v in vectors where v.count != dim { return nil }
        var acc = [Float](repeating: 0, count: dim)
        for v in vectors {
            for i in 0..<dim { acc[i] += v[i] }
        }
        let n = Float(vectors.count)
        for i in 0..<dim { acc[i] /= n }
        return acc
    }

    /// Pack `[Float]` to little-endian `Data`. Mirrors `SwiftDataVectorStore.encode`
    /// without coupling that internal helper.
    private static func encodeFloats(_ values: [Float]) -> Data {
        var copy = values
        return copy.withUnsafeMutableBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}
