import Foundation

/// Voice handle for the Kokoro 82M neural TTS. We only ship one voice for the
/// Day 4 demo (`af_heart`, the FluidAudio "regression-tested ship default")
/// because every additional voice pack adds ~5 MB of weights to the bundle
/// without changing the demo story. Future-proofed as an enum so we can swap
/// or A/B voices later without touching the service.
enum KokoroVoice: String, Sendable, CaseIterable {
    /// Default warm female voice. Matches `TtsConstants.recommendedVoice`.
    case afHeart = "af_heart"

    /// Identifier passed straight to `KokoroTtsManager.synthesizeDetailed(voice:)`.
    var fluidAudioId: String { rawValue }

    static let `default`: KokoroVoice = .afHeart
}
