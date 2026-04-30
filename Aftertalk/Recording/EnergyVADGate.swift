import Foundation

/// Energy-based voice activity gate. Sits between `AudioCaptureService` and
/// `MoonshineStreamer` to skip silent audio frames before they reach the
/// streaming encoder.
///
/// ## Why this exists
///
/// Moonshine live streaming can drift behind real time on sustained voiced
/// audio. On a multi-minute recording, small per-chunk drift compounds into
/// perceived transcript lag because audio backs up in the dispatch queue
/// feeding `Stream.addAudio`. The encoder is the wrong place to fix that —
/// instead we trim the input.
///
/// Conversational meeting audio is 40–60% silence (turn gaps, breaths, the
/// pauses between sentences). Dropping those frames before they reach
/// Moonshine preserves the headroom the live preview needs to stay real-time
/// on iPhone.
///
/// This is the canonical pattern: WhisperKit, Pipecat, Google Live Caption,
/// and `whisper.cpp -vad` all wrap a streaming ASR in a VAD gate. We pick
/// energy-based RMS over a learned model (Silero, TEN-VAD) because:
///   - Inference cost: ~5 µs/chunk vs. ~1 ms (Silero) / ~80 ms (SmartTurn).
///   - Zero model load — no warmup penalty on first record press.
///   - For a quiet room with a speaker 1–2 m from the iPhone mic, an RMS
///     threshold with hysteresis and a hold tail is robust enough.
///   - Easy to swap for a learned VAD later behind the same protocol.
///
/// ## Tuning
///
/// Operates on the post-`AudioPreprocessor.boostForASR` signal (linear gain
/// 2× then `tanh` soft-clip), so all thresholds are referenced to that
/// boosted signal:
///
///   - `speechThresholdDb = -38`  ← typical conversational voice on iPhone
///                                   mic at 1 m, after the 6 dB ASR boost
///   - `silenceThresholdDb = -50` ← clear room tone
///   - hysteresis band [-50, -38] handles soft consonants and whispers
///   - `holdSeconds = 0.30`       ← keep forwarding 300 ms after RMS drops,
///                                   so word-final consonants aren't chopped
///   - `preRollSeconds = 0.20`    ← prepend 200 ms of audio captured during
///                                   the preceding silence on each
///                                   silence→speech transition, so Moonshine
///                                   sees the natural lead-in to the first
///                                   phoneme. Without this, first words
///                                   often arrive truncated.
///
/// ## Threading
///
/// Single-writer: `gate(samples:)` is called only from the AVAudioEngine
/// tap closure, which runs on a dedicated audio render thread. Mutable
/// state is therefore safe under `nonisolated(unsafe)` without extra locks
/// — the same threading model `AudioCaptureService` itself relies on.
final class EnergyVADGate: @unchecked Sendable {
    /// Diagnostic counters, sampled by the debug overlay so we can verify
    /// on device that the gate is actually shedding silence.
    struct Stats: Sendable {
        var samplesIn: Int = 0
        var samplesForwarded: Int = 0
        var samplesDropped: Int = 0
        var transitions: Int = 0  // silence→speech edges (utterance starts)
        var inSpeech: Bool = false
        /// Most-recent chunk's RMS in dBFS. Updated every `gate(samples:)`
        /// call; useful as a live VU meter on the debug overlay.
        var lastRmsDb: Float = -120
        /// Exponential moving average of the noise-floor RMS — only updated
        /// on chunks that the gate classified as silence. Far-field
        /// classroom recordings typically sit between -50 and -60 dBFS for
        /// noise floor; quiet office around -65 to -75 dBFS.
        var noiseFloorDb: Float = -120
        /// Exponential moving average of speech-chunk RMS — only updated
        /// on chunks classified as speech. Combined with `noiseFloorDb`
        /// this gives a working SNR estimate.
        var speechRmsDb: Float = -120
        /// `samplesForwarded / samplesIn`. Lower is better (more silence
        /// recovered). Conversational target: 0.40–0.65. If this stays
        /// near 1.0 the gate isn't doing anything — recheck thresholds or
        /// noise floor.
        var forwardRatio: Double {
            guard samplesIn > 0 else { return 0 }
            return Double(samplesForwarded) / Double(samplesIn)
        }
        /// Speech-to-noise margin in dB (speechRms - noiseFloor). Below
        /// ~10 dB indicates poor capture conditions — a "Move closer to
        /// speaker" hint for the user. Returns 0 until both averages have
        /// observed at least one chunk of their respective type.
        var snrDb: Float {
            guard speechRmsDb > -120, noiseFloorDb > -120 else { return 0 }
            return speechRmsDb - noiseFloorDb
        }
    }

    private let speechThresholdDb: Float
    private let silenceThresholdDb: Float
    private let holdSamples: Int
    private let preRollCapacity: Int

    nonisolated(unsafe) private var inSpeech: Bool = false
    nonisolated(unsafe) private var samplesSinceSpeech: Int = 0
    /// Ring buffer of the most recent audio (during silence). Drained on
    /// each silence→speech edge so the encoder sees pre-roll context.
    nonisolated(unsafe) private var preRoll: [Float]
    nonisolated(unsafe) private var preRollHead: Int = 0
    nonisolated(unsafe) private var preRollFilled: Int = 0
    nonisolated(unsafe) private var stats = Stats()

    init(sampleRate: Int = 16_000,
         speechThresholdDb: Float = -38,
         silenceThresholdDb: Float = -50,
         holdSeconds: Float = 0.30,
         preRollSeconds: Float = 0.20) {
        precondition(sampleRate > 0, "EnergyVADGate: sampleRate must be > 0")
        precondition(speechThresholdDb > silenceThresholdDb,
                     "EnergyVADGate: speech threshold must be above silence threshold for hysteresis to function")
        self.speechThresholdDb = speechThresholdDb
        self.silenceThresholdDb = silenceThresholdDb
        self.holdSamples = max(0, Int(Float(sampleRate) * holdSeconds))
        self.preRollCapacity = max(1, Int(Float(sampleRate) * preRollSeconds))
        self.preRoll = [Float](repeating: 0, count: self.preRollCapacity)
    }

    /// Profile-driven init. Routes the four threshold/timing values from a
    /// `RecordingProfile` so the gate, the preprocessor, and any future
    /// settings UI all read from one source of truth. Default arg keeps
    /// behaviour identical to the long-form init at `.normal` values.
    convenience init(sampleRate: Int = 16_000, profile: RecordingProfile = .normal) {
        self.init(
            sampleRate: sampleRate,
            speechThresholdDb: profile.speechThresholdDb,
            silenceThresholdDb: profile.silenceThresholdDb,
            holdSeconds: profile.holdSeconds,
            preRollSeconds: profile.preRollSeconds
        )
    }

    /// Process a chunk of (boosted, 16 kHz) samples. Returns the audio that
    /// should be forwarded to Moonshine — either an empty array (silence,
    /// drop), the input chunk verbatim (mid-speech), or pre-roll prepended
    /// to the input chunk (silence→speech edge).
    @inlinable
    func gate(samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        stats.samplesIn += samples.count

        let rmsDb = Self.rmsDecibels(samples)
        stats.lastRmsDb = rmsDb
        let aboveSpeech = rmsDb >= speechThresholdDb
        let belowSilence = rmsDb < silenceThresholdDb

        // Maintain exponential moving averages for SNR estimation. Update
        // the speech average on speech-classified chunks only and the
        // noise-floor average on silence-classified chunks only — mixing
        // would smear the two together. Alpha 0.1 means each chunk
        // contributes ~10% to the running average; matches a ~10-chunk
        // half-life at our 21 ms / chunk pump rate (~200 ms half-life).
        let alpha: Float = 0.1
        if aboveSpeech {
            if stats.speechRmsDb <= -120 {
                stats.speechRmsDb = rmsDb
            } else {
                stats.speechRmsDb = (1 - alpha) * stats.speechRmsDb + alpha * rmsDb
            }
        } else if belowSilence {
            if stats.noiseFloorDb <= -120 {
                stats.noiseFloorDb = rmsDb
            } else {
                stats.noiseFloorDb = (1 - alpha) * stats.noiseFloorDb + alpha * rmsDb
            }
        }

        if aboveSpeech {
            // Mid-speech or silence→speech edge.
            if !inSpeech {
                inSpeech = true
                stats.transitions += 1
                stats.inSpeech = true
                // Drain pre-roll first so Moonshine sees the natural
                // lead-in into the first phoneme.
                let preRollAudio = drainPreRoll()
                stash(samples: samples)
                samplesSinceSpeech = 0
                let out = preRollAudio + samples
                stats.samplesForwarded += out.count
                return out
            }
            samplesSinceSpeech = 0
            stash(samples: samples)
            stats.samplesForwarded += samples.count
            return samples
        }

        if inSpeech {
            // Tail-decay phase: keep forwarding until we've sat below the
            // silence threshold for `holdSamples`, then drop into silence.
            samplesSinceSpeech += samples.count
            if belowSilence && samplesSinceSpeech >= holdSamples {
                inSpeech = false
                stats.inSpeech = false
                // Forward this final chunk so the encoder sees the trailing
                // silence — Moonshine uses tail energy for endpointing.
                stash(samples: samples)
                stats.samplesForwarded += samples.count
                return samples
            }
            stash(samples: samples)
            stats.samplesForwarded += samples.count
            return samples
        }

        // Pure silence — buffer for pre-roll on the next transition, drop
        // from the encoder feed. This is where the compute savings come
        // from: every silence chunk we drop here is one fewer encoder run.
        stash(samples: samples)
        stats.samplesDropped += samples.count
        return []
    }

    /// Snapshot the current diagnostic counters. Cheap enough to call from
    /// the diag publish path without contention.
    func snapshot() -> Stats {
        return stats
    }

    func reset() {
        inSpeech = false
        samplesSinceSpeech = 0
        preRollHead = 0
        preRollFilled = 0
        for i in 0..<preRoll.count { preRoll[i] = 0 }
        stats = Stats()
    }

    // MARK: - Internals

    /// Append samples to the pre-roll ring buffer. We over-write old data;
    /// only the most recent `preRollCapacity` samples are retained.
    @inlinable
    func stash(samples: [Float]) {
        for s in samples {
            preRoll[preRollHead] = s
            preRollHead = (preRollHead + 1) % preRollCapacity
            if preRollFilled < preRollCapacity { preRollFilled += 1 }
        }
    }

    /// Read out the pre-roll ring buffer in chronological order. Empties
    /// it as a side-effect — pre-roll only spans one transition so we
    /// don't want it being replayed across a second utterance.
    private func drainPreRoll() -> [Float] {
        guard preRollFilled > 0 else { return [] }
        var out = [Float](repeating: 0, count: preRollFilled)
        // The oldest sample sits at preRollHead - preRollFilled (mod cap)
        // when the buffer is partially filled, or at preRollHead exactly
        // when it's full.
        let start: Int
        if preRollFilled == preRollCapacity {
            start = preRollHead
        } else {
            start = (preRollHead - preRollFilled + preRollCapacity) % preRollCapacity
        }
        var idx = start
        for i in 0..<preRollFilled {
            out[i] = preRoll[idx]
            idx = (idx + 1) % preRollCapacity
        }
        // Wipe so the next transition doesn't replay stale audio.
        preRollFilled = 0
        return out
    }

    /// Plain RMS in dBFS over the chunk. Cheap: one pass, one sqrt, one log.
    /// Returns -120 for (effectively) silence so `log10f(0)` never bites.
    @inlinable
    static func rmsDecibels(_ samples: [Float]) -> Float {
        var sumSq: Float = 0
        for x in samples { sumSq += x * x }
        let mean = sumSq / Float(samples.count)
        let rms = sqrtf(mean)
        if rms < 1e-7 { return -120 }
        return 20 * log10f(rms)
    }
}
