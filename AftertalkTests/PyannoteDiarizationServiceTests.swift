import XCTest
import os
#if canImport(FluidAudio)
import FluidAudio
#endif
@testable import Aftertalk

/// Pure-logic tests for `PyannoteDiarizationService.collapseSpuriousClusters`.
///
/// The function is a static post-processor — it takes `[TimedSpeakerSegment]`
/// (the FluidAudio output) plus a `Logger` and returns a smaller
/// `[TimedSpeakerSegment]` with ghost clusters merged into their nearest real
/// cluster. We test it without spinning up the real Pyannote graphs by
/// hand-crafting `TimedSpeakerSegment` fixtures with embeddings positioned
/// relative to each other to exercise specific failure modes.
///
/// Coverage focuses on invariants the implementation must hold under any
/// future change:
///
///   1. **No ghost-to-ghost merge cycles.** Two ghost clusters that are
///      mutually closer to each other than to any real cluster must still
///      collapse into the real cluster — not into each other.
///   2. **Real clusters survive.** Two clusters with ample airtime + segment
///      count must not be touched.
///   3. **Short-recording protection.** When every cluster qualifies as
///      small, none get merged (a genuinely brief recording should keep
///      whatever signal it captured).
final class PyannoteDiarizationServiceTests: XCTestCase {

    #if canImport(FluidAudio)
    private let testLogger = Logger(
        subsystem: "com.theaayushstha.aftertalk",
        category: "TestDiarization"
    )

    /// Reviewer-requested regression. Layout:
    ///
    ///   - R: real cluster, 6 segments × 5 s = 30 s airtime, embedding ≈ [1,0,0]
    ///   - A: ghost, 1 segment, 0.5 s airtime, embedding ≈ [0.6,0.4,0]
    ///   - B: ghost, 1 segment, 0.5 s airtime, embedding ≈ [0.5,0.5,0]
    ///
    /// `cosine(A,B)` ≈ 0.98 → distance ≈ 0.02
    /// `cosine(A,R)` ≈ 0.83 → distance ≈ 0.17
    ///
    /// So A's nearest centroid is B (and vice-versa). Before the fix, the
    /// ghost-to-ghost merge created a remap cycle `{A: B, B: A}`. The chain
    /// resolver's cycle guard left the cycle intact; the segment relabel
    /// then swapped A's and B's IDs, leaving 3 distinct speaker IDs in the
    /// output even though the log claimed two ghosts had merged.
    ///
    /// The fix constrains the merge target search to non-ghost clusters
    /// only (`nonSmallIds`). With that, `remap.keys` ⊆ candidates and
    /// `remap.values` ⊆ nonSmallIds become disjoint by construction, so
    /// chains cannot form. Both A and B point at R; final unique speaker
    /// count is 1.
    func testTwoCloseGhostsCollapseIntoRealNotEachOther() throws {
        var segments: [TimedSpeakerSegment] = []

        // Real cluster R: dominant airtime, well-separated embedding.
        for i in 0..<6 {
            segments.append(TimedSpeakerSegment(
                speakerId: "R",
                embedding: [1.0, 0.0, 0.0],
                startTimeSeconds: Float(i) * 5,
                endTimeSeconds: Float(i) * 5 + 5,
                qualityScore: 0.9
            ))
        }
        // Ghost A: 1 segment, 0.5 s, embedding biased away from R toward B.
        segments.append(TimedSpeakerSegment(
            speakerId: "A",
            embedding: [0.6, 0.4, 0.0],
            startTimeSeconds: 30,
            endTimeSeconds: 30.5,
            qualityScore: 0.5
        ))
        // Ghost B: 1 segment, 0.5 s, embedding closer to A than to R.
        segments.append(TimedSpeakerSegment(
            speakerId: "B",
            embedding: [0.5, 0.5, 0.0],
            startTimeSeconds: 31,
            endTimeSeconds: 31.5,
            qualityScore: 0.5
        ))

        let result = PyannoteDiarizationService.collapseSpuriousClusters(
            segments,
            logger: testLogger
        )

        let unique = Set(result.map { $0.speakerId })
        XCTAssertEqual(
            unique,
            ["R"],
            "Both ghosts must collapse into R, not into each other. Got: \(unique.sorted())"
        )
        XCTAssertEqual(result.count, segments.count, "All segments must survive (relabeled, not dropped)")
    }

    /// Two real clusters (each ≥ 3 segments AND ≥ 5% airtime) must not be
    /// touched by collapse. Guards against an over-eager fix that mistakes
    /// a short-but-real second speaker for a ghost.
    func testTwoRealClustersAreLeftIntact() throws {
        var segments: [TimedSpeakerSegment] = []
        for i in 0..<6 {
            // Speaker R1: 6 segments × 5 s = 30 s airtime, embedding [1,0,0]
            segments.append(TimedSpeakerSegment(
                speakerId: "R1",
                embedding: [1.0, 0.0, 0.0],
                startTimeSeconds: Float(i) * 10,
                endTimeSeconds: Float(i) * 10 + 5,
                qualityScore: 0.9
            ))
            // Speaker R2: 6 segments × 4 s = 24 s airtime, embedding [0,1,0]
            // Distinctly orthogonal to R1 so neither qualifies as the
            // other's centroid neighbor.
            segments.append(TimedSpeakerSegment(
                speakerId: "R2",
                embedding: [0.0, 1.0, 0.0],
                startTimeSeconds: Float(i) * 10 + 5,
                endTimeSeconds: Float(i) * 10 + 9,
                qualityScore: 0.85
            ))
        }

        let result = PyannoteDiarizationService.collapseSpuriousClusters(
            segments,
            logger: testLogger
        )

        let unique = Set(result.map { $0.speakerId })
        XCTAssertEqual(
            unique,
            ["R1", "R2"],
            "Two real clusters must survive collapse. Got: \(unique.sorted())"
        )
    }

    /// When every cluster qualifies as small (≤ minSegments AND <
    /// minAirtimeFraction), the function must keep all of them. A genuinely
    /// short recording shouldn't get its only signal merged away.
    func testAllSmallClustersAreAllPreserved() throws {
        let segments: [TimedSpeakerSegment] = [
            TimedSpeakerSegment(
                speakerId: "A",
                embedding: [1.0, 0.0, 0.0],
                startTimeSeconds: 0,
                endTimeSeconds: 0.5,
                qualityScore: 0.5
            ),
            TimedSpeakerSegment(
                speakerId: "B",
                embedding: [0.0, 1.0, 0.0],
                startTimeSeconds: 0.5,
                endTimeSeconds: 1.0,
                qualityScore: 0.5
            ),
        ]

        let result = PyannoteDiarizationService.collapseSpuriousClusters(
            segments,
            logger: testLogger
        )

        let unique = Set(result.map { $0.speakerId })
        XCTAssertEqual(
            unique,
            ["A", "B"],
            "All-small recording must keep every cluster. Got: \(unique.sorted())"
        )
    }
    #else
    /// CI environments without FluidAudio (pure-Linux) — keep the test target
    /// compilable but skip the bodies. On every Apple platform CI we test on,
    /// FluidAudio is available so this branch is never hit in practice.
    func testFluidAudioRequired() throws {
        throw XCTSkip("FluidAudio module not available")
    }
    #endif
}
