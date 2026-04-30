import Foundation
import Darwin

/// Pre-ASR audio conditioner. Sits between `AVAudioConverter`'s 16 kHz output
/// and the Moonshine streaming pump. Only the ASR feed is touched — the WAV
/// destination keeps the raw, un-boosted samples so post-recording Parakeet
/// polish and demo playback stay honest.
///
/// Why this exists: iPhone's bottom mic at >1 m loses ~15 dB SNR. The mic's
/// own AGC partially compensates but pushes the input into a low-amplitude
/// regime where Moonshine's encoder gets unreliable — consonants disappear,
/// "stage" comes out as "Sage", "decision" becomes "vision". A fixed linear
/// gain pulls the input back into the model's typical operating range.
///
/// What it does NOT do: pre-emphasis (HF boost). Pre-emphasis would help
/// consonants but the Whisper-distillation training data Moonshine was built
/// on doesn't include it — adding it at inference is a domain shift with
/// uncertain effect. Held back as a future experiment.
enum AudioPreprocessor {
    /// Default linear gain (~6 dB). Matches `RecordingProfile.normal.gain`
    /// — sized so a normal-volume close speaker stays below the soft-clip
    /// knee while a ~2 m speaker is meaningfully louder. The
    /// `boostForASR(_:gain:)` overload below honors a different gain when
    /// a far-field profile is wired through (currently no UI surface, see
    /// `RecordingProfile.farField`).
    static let linearGain: Float = 2.0

    /// Apply gain + tanh soft-clip. Soft-clip keeps |y| < 1.0 without the
    /// audible click of hard-clipping — important because the resulting
    /// samples feed Moonshine's STFT, which is sensitive to discontinuities.
    /// Returns a new array; never mutates the caller's slice.
    ///
    /// Defaulting `gain` to `linearGain` keeps existing call sites
    /// bit-identical — they don't have to opt in to use the profile-aware
    /// signature.
    @inlinable
    static func boostForASR(_ samples: [Float], gain: Float = linearGain) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: samples.count)
        let g = gain
        for i in 0..<samples.count {
            let scaled = samples[i] * g
            // tanh approximates a soft knee around |x| ≈ 0.6. Above that the
            // curve compresses gracefully; well below it the gain is ~linear.
            out[i] = tanhf(scaled)
        }
        return out
    }
}
