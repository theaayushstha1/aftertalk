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
    /// Linear gain. ~6 dB. Sized so a normal-volume close speaker stays
    /// below the soft-clip knee while a 2 m speaker is meaningfully louder.
    static let linearGain: Float = 2.0

    /// Apply gain + tanh soft-clip. Soft-clip keeps |y| < 1.0 without the
    /// audible click of hard-clipping — important because the resulting
    /// samples feed Moonshine's STFT, which is sensitive to discontinuities.
    /// Returns a new array; never mutates the caller's slice.
    @inlinable
    static func boostForASR(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: samples.count)
        let g = linearGain
        for i in 0..<samples.count {
            let scaled = samples[i] * g
            // tanh approximates a soft knee around |x| ≈ 0.6. Above that the
            // curve compresses gracefully; well below it the gain is ~linear.
            out[i] = tanhf(scaled)
        }
        return out
    }
}
