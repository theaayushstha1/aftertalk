import XCTest
@testable import Aftertalk

/// Pure-logic tests for `EnergyVADGate.gate(samples:)`.
///
/// We exercise the gate against synthesized 16 kHz Float32 buffers of
/// known RMS so we can assert exactly what the gate forwards / drops /
/// emits as pre-roll.
///
/// Test naming follows the invariant being asserted, not the input shape,
/// because a regression on any of these is a real user-visible bug:
///   - silence-only audio must result in zero forwarded samples
///   - speech must always forward
///   - silence→speech transitions must prepend buffered audio (pre-roll)
///   - speech→silence must keep forwarding for at least `holdSeconds`
final class EnergyVADGateTests: XCTestCase {

    /// Helper: build a chunk of N samples with constant amplitude so RMS is
    /// predictable. RMS dBFS = 20 * log10(amplitude). amplitude = 0.1
    /// gives RMS ≈ -20 dBFS (clearly speech). amplitude = 0.001 gives
    /// RMS ≈ -60 dBFS (clearly silence relative to our -50 silence
    /// threshold).
    private func chunk(amplitude: Float, count: Int = 320) -> [Float] {
        return [Float](repeating: amplitude, count: count)
    }

    func testSilenceOnlyAudioIsAllDropped() {
        let gate = EnergyVADGate()
        // Feed 50 chunks of pure silence (-60 dBFS << -50 silence threshold).
        // Pre-roll buffer fills but no transition fires, so nothing reaches
        // the streamer.
        for _ in 0..<50 {
            let out = gate.gate(samples: chunk(amplitude: 0.001))
            XCTAssertTrue(out.isEmpty, "Pure silence must not forward any samples to the encoder")
        }
        let stats = gate.snapshot()
        XCTAssertGreaterThan(stats.samplesIn, 0)
        XCTAssertEqual(stats.samplesForwarded, 0)
        XCTAssertEqual(stats.transitions, 0)
        XCTAssertFalse(stats.inSpeech)
    }

    func testSpeechIsAlwaysForwarded() {
        let gate = EnergyVADGate()
        // Skip silence preamble; every chunk is speech.
        var totalForwarded = 0
        for _ in 0..<10 {
            let out = gate.gate(samples: chunk(amplitude: 0.1))  // ~ -20 dBFS
            totalForwarded += out.count
        }
        let stats = gate.snapshot()
        XCTAssertGreaterThan(totalForwarded, 0)
        XCTAssertGreaterThanOrEqual(stats.transitions, 1, "First speech chunk must register as silence→speech edge")
        XCTAssertTrue(stats.inSpeech)
    }

    func testSilenceToSpeechTransitionPrependsPreRoll() {
        let gate = EnergyVADGate()
        // 5 silence chunks fill ~1600 samples of the pre-roll ring (capacity
        // is 200 ms × 16 kHz = 3200, so the buffer is half-full).
        for _ in 0..<5 {
            _ = gate.gate(samples: chunk(amplitude: 0.001))
        }
        // First speech chunk should return pre-roll (buffered silence) +
        // the speech chunk itself. Output count must exceed input count.
        let speech = chunk(amplitude: 0.1)
        let out = gate.gate(samples: speech)
        XCTAssertGreaterThan(
            out.count,
            speech.count,
            "Silence→speech edge must prepend pre-roll audio so the encoder sees the lead-in"
        )
    }

    func testSpeechToSilenceForwardsHoldTail() {
        let gate = EnergyVADGate(holdSeconds: 0.30)
        // Drive into speech first.
        for _ in 0..<3 {
            _ = gate.gate(samples: chunk(amplitude: 0.1))
        }
        // Now feed silence chunks. The first ~300 ms (holdSeconds) of
        // silence should still be forwarded so trailing soft consonants
        // survive. At 320-sample chunks (= 20 ms each), 15 chunks = 300 ms.
        var forwardedAfterSpeech = 0
        for _ in 0..<5 {  // 5 × 20 ms = 100 ms — well under hold
            let out = gate.gate(samples: chunk(amplitude: 0.0001))  // ~-80 dBFS
            forwardedAfterSpeech += out.count
        }
        XCTAssertGreaterThan(
            forwardedAfterSpeech,
            0,
            "Hold tail must forward silence within the hold window so word-final consonants aren't chopped"
        )
    }

    func testResetWipesGateState() {
        let gate = EnergyVADGate()
        for _ in 0..<10 {
            _ = gate.gate(samples: chunk(amplitude: 0.1))
        }
        XCTAssertGreaterThan(gate.snapshot().samplesIn, 0)
        XCTAssertTrue(gate.snapshot().inSpeech)

        gate.reset()
        let after = gate.snapshot()
        XCTAssertEqual(after.samplesIn, 0)
        XCTAssertEqual(after.samplesForwarded, 0)
        XCTAssertEqual(after.transitions, 0)
        XCTAssertFalse(after.inSpeech)
    }

    func testFarFieldProfileLowersThresholds() {
        // Build two gates, one Normal and one FarField, fed the same
        // -42 dBFS audio (between Normal's -38 speech threshold and
        // FarField's -50 speech threshold). Normal must classify as
        // silence, FarField must classify as speech.
        let normal = EnergyVADGate(profile: .normal)
        let farField = EnergyVADGate(profile: .farField)
        // amplitude ≈ 0.0079 → RMS ≈ -42 dBFS
        let mid = chunk(amplitude: 0.0079)
        // First chunk for each gate.
        _ = normal.gate(samples: mid)
        _ = farField.gate(samples: mid)
        XCTAssertFalse(normal.snapshot().inSpeech, "Normal profile must reject -42 dBFS as speech")
        XCTAssertTrue(farField.snapshot().inSpeech, "FarField profile must accept -42 dBFS as speech")
    }
}
