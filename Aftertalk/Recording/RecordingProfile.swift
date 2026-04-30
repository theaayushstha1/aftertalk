import Foundation

/// Bundles the audio-conditioning + VAD parameters that change between
/// near-field meeting capture and far-field lecture/classroom capture.
///
/// Two factories shipped today:
///
///   - `.normal` — the values the app has shipped to date. Tuned for a phone
///     held within ~2 m of one or two speakers, voices around -28 to -36 dBFS
///     after Apple's mic AGC. This is the demo path and the default
///     everywhere — the public API of `EnergyVADGate` and
///     `AudioPreprocessor` keeps backward-compatible defaults that match
///     `.normal` so any call site that doesn't opt in stays on the
///     existing behaviour.
///
///   - `.farField` — wired but NOT exposed via UI yet. Compiled in so a
///     future Settings toggle (or A/B harness) can flip the recording
///     profile without touching the gate / preprocessor / pipeline. The
///     thresholds reflect what reviewer profile tuning suggested for a
///     speaker 10–30 ft away through one iPhone mic. Honest framing is in
///     the README "what I'd build with another two weeks" — far-field is
///     fundamentally microphone-physics-limited and a software profile
///     alone won't deliver lecture-hall accuracy.
///
/// Why a struct instead of an enum: the parameters compose naturally and we
/// may want to tweak one axis independently in tests (e.g. holdSeconds for
/// `EnergyVADGate` regression tests). An enum would force every test to
/// declare a new case for each variant.
struct RecordingProfile: Sendable, Hashable {
    /// Linear gain applied by `AudioPreprocessor.boostForASR` before tanh
    /// soft-clip. Higher = more headroom for quiet/distant speakers, also
    /// amplifies room noise proportionally.
    let gain: Float

    /// Above this RMS, `EnergyVADGate` considers the chunk speech.
    let speechThresholdDb: Float

    /// Below this RMS, the gate considers the chunk silence (hysteresis
    /// band between the two thresholds prevents thrashing on soft
    /// consonants and breaths).
    let silenceThresholdDb: Float

    /// After RMS drops below the silence threshold, the gate keeps
    /// forwarding for this long so trailing soft consonants survive.
    let holdSeconds: Float

    /// On a silence→speech transition, the gate prepends this much of the
    /// preceding audio so the encoder sees the natural lead-in.
    let preRollSeconds: Float

    /// Default profile. Bit-identical to the values the app has shipped
    /// to date — confirmed against `EnergyVADGate.init`'s previous
    /// defaults and `AudioPreprocessor.linearGain`. Changing this struct
    /// changes the demo path; review carefully.
    static let normal = RecordingProfile(
        gain: 2.0,
        speechThresholdDb: -38,
        silenceThresholdDb: -50,
        holdSeconds: 0.30,
        preRollSeconds: 0.20
    )

    /// Far-field profile. Wired but not user-selectable yet — kept here so
    /// the structure is in place for a future Classroom Mode commit. The
    /// values follow the recommendation from the late-Day-7 reviewer pass:
    /// VAD thresholds 12 dB lower so quiet far speakers register, hold
    /// tail nearly tripled so a soft trailing consonant from the lecturer
    /// has enough decay for the gate to keep forwarding it, gain bumped
    /// to 3.5× so a speaker 10 ft away lands closer to the encoder's
    /// trained dynamic range. Pre-roll lengthened to 0.5 s for the same
    /// reason — far-field utterances often start before the gate
    /// crosses the speech threshold.
    static let farField = RecordingProfile(
        gain: 3.5,
        speechThresholdDb: -50,
        silenceThresholdDb: -62,
        holdSeconds: 0.80,
        preRollSeconds: 0.50
    )
}
