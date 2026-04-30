> **Archived planning log.** This was a daily brief written before the work shipped. Some component picks (gte-small, sqlite-vec, target latency numbers) were superseded by the actual implementation. For the current architecture see [README.md](../README.md), [DECISIONS.md](../DECISIONS.md), and [THOUGHT-PROCESS.md](../THOUGHT-PROCESS.md).

---

# Day 4 — FluidAudio API Recon (v0.14.2)

Read-only research into the actual FluidAudio Swift sources checked out at:

`~/Library/Developer/Xcode/DerivedData/Aftertalk-fhqatrhukqwwbxbcdbwghyoifriu/SourcePackages/checkouts/FluidAudio/`

Package version: **0.14.2** (SPM, single product `FluidAudio` — see `Package.swift:11-22`).
Swift tools version: **6.0**. Min platforms: macOS 14, iOS 17.

> Critical correction up-front: there is **only one library product / target name** to import — `FluidAudio`. Both Kokoro TTS and Pyannote diarization live inside it. There is no separate `Kokoro` or `Diarization` SwiftPM target.

---

## SPM target name

```swift
import FluidAudio
```

`Package.swift:11-22` exposes:

```swift
products: [
    .library(name: "FluidAudio", targets: ["FluidAudio"]),
    .executable(name: "fluidaudiocli", targets: ["FluidAudioCLI"]),
],
```

`FluidAudio` depends on two C/C++ wrapper targets (`FastClusterWrapper`, `MachTaskSelfWrapper`) — these are transitive and not import-able by us. We only import `FluidAudio`.

Cache directory for downloaded model bundles (default):

```
~/Library/Application Support/FluidAudio/Models/<repo.folderName>/
```

(`Sources/FluidAudio/Shared/MLModelConfigurationUtils.swift:25-35`)

The Kokoro path uses a different default — see Kokoro section below.

---

# 1. KOKORO TTS

There are **two distinct Kokoro backends** in FluidAudio. Pick one. They are not interchangeable.

| | `KokoroTtsManager` (default) | `KokoroAneManager` (ANE-resident) |
|---|---|---|
| Type | `public final class` (not actor, not Sendable) | `public actor` |
| HF repo | `FluidInference/kokoro-82m-coreml` | `FluidInference/kokoro-82m-coreml/ANE` |
| Voices | Multi (af_heart, af_alloy, … 50+) | Single (`af_heart` only) |
| Long input | Built-in chunker | ≤ 510 IPA tokens (no chunker) |
| Custom lexicon | Yes | No |
| Speed on Apple Silicon | Baseline | 3–11× faster RTFx |
| iOS 26 ANE quirk | Affected; doc recommends `.cpuAndGPU` | Empirical default per-stage compute units |
| Streaming API | **No** (one-shot per call) | **No** (one-shot per call) |

Recommendation for Aftertalk: start with **`KokoroTtsManager`** (default `.all`, switch to `.cpuAndGPU` if we hit the iOS 26 ANE compiler bug). It's the documented "shipping default" path, has multi-voice, and has chunking which we'll need for sentence-streaming a paragraph answer.

> README explicitly states streaming is **No** for Kokoro:
> `README.md:551` table row "Streaming | Yes (PocketTTS) | No (Kokoro)".
> To stream answers to the user we feed Kokoro **one sentence at a time** and concatenate the per-call WAV bytes. The internal `chunks: [ChunkInfo]` field in `SynthesisResult` does expose per-chunk Float32 PCM samples, but chunks are formed inside one call — they are not yielded as an `AsyncSequence`.

## 1.1 Top-level type

`Sources/FluidAudio/TTS/Kokoro/KokoroTtsManager.swift:38`:

```swift
public final class KokoroTtsManager {
    public init(
        defaultVoice: String = TtsConstants.recommendedVoice,
        defaultSpeakerId: Int = 0,
        directory: URL? = nil,
        computeUnits: MLComputeUnits = .all,
        modelCache: KokoroModelCache? = nil,
        customLexicon: TtsCustomLexicon? = nil
    )
    public var isAvailable: Bool { get }
    public func initialize(preloadVoices: Set<String>? = nil) async throws
    public func initialize(models: TtsModels, preloadVoices: Set<String>? = nil) async throws
    public func synthesize(text:voice:voiceSpeed:speakerId:variantPreference:deEss:) async throws -> Data
    public func synthesizeDetailed(...) async throws -> KokoroSynthesizer.SynthesisResult
    public func synthesizeToFile(text:outputURL:...) async throws
    public func setDefaultVoice(_ voice: String, speakerId: Int = 0) async throws
    public func setCustomLexicon(_ lexicon: TtsCustomLexicon?)
    public var currentCustomLexicon: TtsCustomLexicon? { get }
    public func cleanup()
}
```

`final class` — **not** Sendable, **not** an actor. We need to wrap it in an actor or pin it to a single isolation domain (e.g. a dedicated `@MainActor` boundary or a custom service actor) under Swift 6 strict concurrency. The internal `KokoroModelCache` and `KokoroSynthesizer` use `@TaskLocal` and `nonisolated(unsafe)` heavily, which makes the class unsuitable for true cross-actor use.

For comparison, `KokoroAneManager` (`TTS/KokoroAne/KokoroAneManager.swift:32`) **is** declared `public actor`.

## 1.2 How models are loaded

The factory type is `TtsModels` — a `Sendable` struct, `Sources/FluidAudio/TTS/TtsModels.swift:6`:

```swift
public struct TtsModels: Sendable {
    public init(models: [ModelNames.TTS.Variant: MLModel])
    public var availableVariants: Set<ModelNames.TTS.Variant> { get }
    public func model(for variant: ModelNames.TTS.Variant = .fifteenSecond) -> MLModel?
    public static func download(
        variants requestedVariants: Set<ModelNames.TTS.Variant>? = nil,
        from repo: String = TtsConstants.defaultRepository,
        directory: URL? = nil,
        computeUnits: MLComputeUnits = .all,
        progressHandler: DownloadUtils.ProgressHandler? = nil
    ) async throws -> TtsModels
    public static func cacheDirectoryURL() throws -> URL
}
```

There is **no `KokoroModels.load(from:)` analog**. The flow is:

```swift
// Option A — let the manager do everything (download + load + warm-up)
let manager = KokoroTtsManager()                       // KokoroTtsManager.swift:70
try await manager.initialize()                         // line 124 — calls TtsModels.download internally

// Option B — pre-stage models, then inject
let models = try await TtsModels.download(directory: customDir)   // TtsModels.swift:36
try await manager.initialize(models: models)                       // KokoroTtsManager.swift:109
```

The `directory` parameter is a **base cache directory**, not a single `.mlpackage` URL. Internally `TtsModels.download` appends `Models/` then resolves to `~/.cache/fluidaudio/Models/kokoro/` on macOS, `<.cachesDirectory>/fluidaudio/Models/kokoro/` on iOS (`TtsModels.swift:90-112`).

Default Kokoro variant: `.fifteenSecond` (15s window). See `ModelNames.swift:744`:

```swift
public static let defaultVariant: Variant = .fifteenSecond
```

## 1.3 Actual model file names inside the Kokoro bundle

Ground truth from `Sources/FluidAudio/ModelNames.swift:714-760`:

```swift
public enum TTS {
    public enum Variant: CaseIterable, Sendable {
        case fiveSecond
        case fifteenSecond
        public var fileName: String {
            switch self {
            case .fiveSecond:   return "kokoro_21_5s.mlmodelc"
            case .fifteenSecond: return "kokoro_21_15s.mlmodelc"
            }
        }
    }
    public static var requiredModels: Set<String> {
        Set(Variant.allCases.map(\.fileName))   // both variants
    }
}
```

So the Kokoro repo download produces:

- `kokoro_21_5s.mlmodelc/`
- `kokoro_21_15s.mlmodelc/`

Plus the G2P and multilingual G2P assets bundled alongside (`ModelNames.swift:813-828` — when downloading `.kokoro` repo, the required set is union of TTS variants + `G2P.requiredModels` + `MultilingualG2P.requiredModels`):

- `G2PEncoder.mlmodelc`, `G2PDecoder.mlmodelc`, `g2p_vocab.json` (`ModelNames.swift:697-711`)
- `MultilingualG2PEncoder.mlmodelc`, `MultilingualG2PDecoder.mlmodelc` (`ModelNames.swift:646-657`)

For the **ANE variant** (`KokoroAneManager`), the seven `.mlmodelc` bundles (`ModelNames.swift:764-786`):

- `KokoroAlbert.mlmodelc`
- `KokoroPostAlbert.mlmodelc`
- `KokoroAlignment.mlmodelc`
- `KokoroProsody.mlmodelc`
- `KokoroNoise.mlmodelc`
- `KokoroVocoder.mlmodelc`
- `KokoroTail.mlmodelc`
- `vocab.json`
- `af_heart.bin` (the only voice pack for ANE)

> No `Preprocessor.mlmodelc` here. (That filename belongs to the Parakeet ASR repo — different repo entirely. See `ModelNames.swift:240` for ASR.)

## 1.4 HuggingFace repo IDs

`Sources/FluidAudio/ModelNames.swift:23-24`:

```swift
case kokoro    = "FluidInference/kokoro-82m-coreml"
case kokoroAne = "FluidInference/kokoro-82m-coreml/ANE"
```

And `TtsConstants.swift:59`:

```swift
public static let defaultRepository: String = "FluidInference/kokoro-82m-coreml"
```

The ANE variant is a **subfolder** of the same repo (`remotePath` is `FluidInference/kokoro-82m-coreml`, `subPath` is `"ANE"` — `ModelNames.swift:102-125`).

## 1.5 Synthesis API — return type, sample rate, format

`KokoroTtsManager.swift:129-146`:

```swift
public func synthesize(
    text: String,
    voice: String? = nil,
    voiceSpeed: Float = 1.0,
    speakerId: Int = 0,
    variantPreference: ModelNames.TTS.Variant? = nil,
    deEss: Bool = true
) async throws -> Data
```

> Returns **`Data`** — but the bytes are a complete **WAV file** (RIFF/WAVE header + 16-bit signed PCM little-endian, mono), not raw `[Float]` PCM samples. Built by `AudioWAV.data(from:sampleRate:)` (`Sources/FluidAudio/Shared/AudioConverter.swift:458-508`).
>
> Important: the WAV writer **normalizes samples to the peak amplitude before quantization** (`AudioConverter.swift:462-463`):
>
> ```swift
> let maxVal = samples.map { abs($0) }.max() ?? 1.0
> let norm = maxVal > 0 ? samples.map { $0 / maxVal } : samples
> ```
>
> This means consecutive `synthesize()` calls will have differing per-call peak normalizations, which makes naive byte-concatenation of WAVs sound uneven. To get streaming-quality audio:
>
> 1. Use `synthesizeDetailed(...)` to get raw `[Float]` per chunk (no normalization), OR
> 2. Decode each WAV back to floats and renormalize across the full utterance.

Sample rate: **24,000 Hz mono** (`TtsConstants.swift:50`):

```swift
public static let audioSampleRate: Int = 24_000
```

For streaming, prefer `synthesizeDetailed`. `KokoroTtsManager.swift:148-181`:

```swift
public func synthesizeDetailed(
    text: String,
    voice: String? = nil,
    voiceSpeed: Float = 1.0,
    speakerId: Int = 0,
    variantPreference: ModelNames.TTS.Variant? = nil,
    deEss: Bool = true
) async throws -> KokoroSynthesizer.SynthesisResult
```

`SynthesisResult` shape (`Sources/FluidAudio/TTS/Kokoro/Pipeline/Postprocess/KokoroSynthesizer+Types.swift:18-28`):

```swift
public struct SynthesisResult: Sendable {
    public let audio: Data            // full-utterance WAV (16-bit PCM)
    public let chunks: [ChunkInfo]    // per-internal-chunk metadata + raw [Float] samples
    public let diagnostics: Diagnostics?
}
public struct ChunkInfo: Sendable {
    public let index: Int
    public let text: String
    public let wordCount: Int
    public let words: [String]
    public let atoms: [String]
    public let pauseAfterMs: Int
    public let tokenCount: Int
    public let samples: [Float]                  // raw 24 kHz Float32 PCM, no normalization
    public let variant: ModelNames.TTS.Variant
}
```

For first-audio latency we should call `synthesizeDetailed` and play `chunks[0].samples` as soon as the call returns — but **note** all chunks are computed in parallel inside one call (`KokoroSynthesizer.swift:602-646`, `withThrowingTaskGroup`), so the call doesn't return until the entire utterance is synthesized. To get true sentence-by-sentence streaming, drive `synthesizeDetailed` once per sentence from a `SentenceBoundaryDetector` and stream the resulting `[Float]` to the audio engine.

## 1.6 Streaming API

**There isn't one.** Both `synthesize` and `synthesizeDetailed` are single-shot, awaitable, return when the full audio is materialized. No `AsyncStream`, no `AsyncSequence`, no callback. README confirms (`README.md:551`).

The library *does* offer streaming TTS via `PocketTtsManager` (`Sources/FluidAudio/TTS/PocketTTS/PocketTtsManager.swift`, frame-by-frame autoregressive at 80 ms), but per the project lock list we are using Kokoro. If we discover we need streaming inside the answer, we can either:

1. Drive Kokoro one sentence at a time from the LLM stream (recommended — matches the day-3 sentence-boundary strategy).
2. Switch to `PocketTtsManager` (also in FluidAudio, same import) — voice cloning supported, streaming via `PocketTtsSession` — but no SSML / pronunciation control.

## 1.7 Voice selection

Voice ID is a `String`, optional. `KokoroTtsManager.swift:129-135`:

```swift
public func synthesize(
    text: String,
    voice: String? = nil,            // <-- string voice id
    voiceSpeed: Float = 1.0,
    speakerId: Int = 0,
    ...
)
```

When `voice` is `nil`, the manager picks one of `TtsConstants.availableVoices` indexed by `speakerId` (`KokoroTtsManager.swift:246-254`).

Default voice (`TtsConstants.swift:12`):

```swift
public static let recommendedVoice = "af_heart"
```

Available American English voices regression-tested (`TtsConstants.swift:19-23`):

```
af_alloy, af_aoede, af_bella, af_heart, af_jessica, af_kore, af_nicole, af_nova,
af_river, af_sarah, af_sky, am_adam, am_echo, am_eric, am_fenrir, am_liam,
am_michael, am_onyx, am_puck, am_santa
```

Other locales (BE, ES, FR, HI, IT, JA, PT, ZH) have voice IDs in the list but are explicitly **not QA'd** (the file calls them "experimental, not tested"). For Aftertalk, stick to `af_heart` or `af_nicole`.

## 1.8 Warm-up

`TtsModels.download` runs an automatic warm-up after compilation (`TtsModels.swift:74-85`, `warmUpModel` at `:126-223`). It runs one fake prediction filling the full token window for each variant. So the first real `synthesize` call after `manager.initialize()` is already warm.

If we are wiring `synthesize` into the response loop, **also call `synthesize(text: " ")` (or one ground-truth phrase) once at app start** to JIT the simple-phoneme dictionary (`KokoroSynthesizer.loadSimplePhonemeDictionary()` is lazy, `KokoroTtsManager.swift:118`).

## 1.9 Cleanup / lifecycle

`KokoroTtsManager.swift:239-244`:

```swift
public func cleanup() {
    ttsModels = nil
    isInitialized = false
    assetsReady = false
    ensuredVoices.removeAll(keepingCapacity: false)
}
```

No `deinit` cleanup. We must call `cleanup()` explicitly when ending a session if we want to free CoreML model memory.

`KokoroAneManager` (the actor variant) `cleanup()` at `KokoroAneManager.swift:90-92` similarly drops the underlying `KokoroAneModelStore` state.

## 1.10 Compute units

Default: `.all` — `KokoroTtsManager.swift:74` and `TtsModels.swift:40`.

> README explicitly warns about iOS 26 ANE compiler regressions (`KokoroTtsManager.swift:32-37`):
>
> > "On iOS 26+, use `.cpuAndGPU` to work around ANE compiler regressions ('Cannot retrieve vector from IRValue format int32')."
>
> Recommended call for Aftertalk on iOS 26 device:
>
> ```swift
> let manager = KokoroTtsManager(computeUnits: .cpuAndGPU)
> try await manager.initialize()
> ```
>
> The `KokoroAneManager` opts into per-stage compute units (`KokoroAneModelStore.swift:9-56`) — Albert / PostAlbert / Alignment / Vocoder on `.cpuAndNeuralEngine`, Prosody / Noise / Tail on `.all`. If we want `KokoroAneManager` and want to mirror the iOS 26 workaround, use `KokoroAneComputeUnits.cpuAndGpu` (`KokoroAneModelStore.swift:40-43`).

## 1.11 Memory footprint at load

`SynthesisResult.diagnostics` exposes `variantFootprints: [ModelNames.TTS.Variant: Int]` — bundle directory size in bytes (`KokoroSynthesizer+Types.swift:31`, computed from `directorySize(at:)` in `KokoroSynthesizer.swift:809-813`). The README does not publish a fixed MB number for runtime resident memory. The HF repo describes Kokoro 82M as ~325 MB on disk for both variants combined. **Open question:** runtime resident MB on iPhone Air at `.cpuAndGPU` is unknown; measure on device.

For the ANE variant, the seven `.mlmodelc` bundles total roughly the same on disk; ANE residency cuts CPU/GPU pressure but ANE-resident memory is opaque to us.

---

# 2. PYANNOTE DIARIZATION

## 2.1 Top-level type

`Sources/FluidAudio/Diarizer/Core/DiarizerManager.swift:6`:

```swift
public final class DiarizerManager {
    public init(config: DiarizerConfig = .default)
    public var isAvailable: Bool { get }
    public var segmentationModel: MLModel? { get }
    public let segmentationProcessor: SegmentationProcessor
    public var embeddingExtractor: EmbeddingExtractor?
    public let speakerManager: SpeakerManager
    public func initialize(models: consuming DiarizerModels)        // synchronous, NOT async
    public func cleanup()
    public func validateEmbedding(_ embedding: [Float]) -> Bool
    public func validateAudio<C>(_ samples: C) -> AudioValidationResult
        where C: Collection, C.Element == Float
    public func initializeKnownSpeakers(_ speakers: [Speaker]) async
    public func extractSpeakerEmbedding<C>(from audio: C) throws -> [Float]
        where C: RandomAccessCollection, C.Element == Float, C.Index == Int
    public func performCompleteDiarization<C>(
        _ samples: C, sampleRate: Int = 16000, atTime startTime: TimeInterval = 0
    ) async throws -> DiarizationResult
        where C: RandomAccessCollection, C.Element == Float, C.Index == Int
}
```

`final class`, **not** Sendable, **not** an actor. Same Swift 6 wrapping concern as `KokoroTtsManager`.

> Note: `initialize(models:)` is **synchronous** (no `async`), and uses `consuming` ownership — `DiarizerManager.swift:42`. Don't `await` it.

## 2.2 Model loading

Loader type: `DiarizerModels` (Sendable struct), `Sources/FluidAudio/Diarizer/Core/DiarizerModels.swift:10`:

```swift
public struct DiarizerModels: Sendable {
    public static let requiredModelNames = ModelNames.Diarizer.requiredModels
    public let segmentationModel: MLModel
    public let embeddingModel: MLModel
    public let compilationDuration: TimeInterval

    // Auto-download path
    public static func download(
        to directory: URL? = nil,
        configuration: MLModelConfiguration? = nil,
        progressHandler: DownloadUtils.ProgressHandler? = nil
    ) async throws -> DiarizerModels                                  // line 40

    // Convenience alias of `download`
    public static func downloadIfNeeded(...) async throws -> DiarizerModels   // line 92

    // Pre-staged-bundle path (offline)
    public static func load(
        localSegmentationModel: URL,
        localEmbeddingModel: URL,
        configuration: MLModelConfiguration? = nil
    ) async throws -> DiarizerModels                                  // line 120

    // Auto-download alias
    public static func load(
        from directory: URL? = nil,
        configuration: MLModelConfiguration? = nil,
        progressHandler: DownloadUtils.ProgressHandler? = nil
    ) async throws -> DiarizerModels                                  // line 83

    public static func defaultModelsDirectory() -> URL                // line 100
}
```

Two distinct `load(...)` overloads:

- `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:configuration:)` — for offline / bundled / pre-staged Core ML bundles. Each parameter is a **URL to a single `.mlmodelc` folder bundle** (not the parent directory).
- `DiarizerModels.load(from:)` — convenience that delegates to `download(to:)`. Parameter is the **base directory**, not a single bundle URL.

Bundle file names (`Sources/FluidAudio/ModelNames.swift:198-209`):

```swift
public enum Diarizer {
    public static let segmentation = "pyannote_segmentation"
    public static let embedding    = "wespeaker_v2"
    public static let segmentationFile = segmentation + ".mlmodelc"   // pyannote_segmentation.mlmodelc
    public static let embeddingFile    = embedding + ".mlmodelc"      // wespeaker_v2.mlmodelc
    public static let requiredModels: Set<String> = [
        segmentationFile,
        embeddingFile,
    ]
}
```

Both segmentation **and** embedding ship from the same repo. The default cache dir is:

```
~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/
├── pyannote_segmentation.mlmodelc
└── wespeaker_v2.mlmodelc
```

(`MLModelConfigurationUtils.swift:25-35` + `Repo.diarizer.folderName == "speaker-diarization-coreml"` — `ModelNames.swift:188-191`, default branch.)

## 2.3 HuggingFace repo ID

`Sources/FluidAudio/ModelNames.swift:22`:

```swift
case diarizer = "FluidInference/speaker-diarization-coreml"
```

## 2.4 Inference API — input & output

```swift
public func performCompleteDiarization<C>(
    _ samples: C,
    sampleRate: Int = 16000,
    atTime startTime: TimeInterval = 0
) async throws -> DiarizationResult
where C: RandomAccessCollection, C.Element == Float, C.Index == Int
```

(`DiarizerManager.swift:153-156`)

- **Input**: `RandomAccessCollection<Float>` — works with `[Float]`, `ArraySlice<Float>`, `ContiguousArray<Float>`. Mono. Must already be **16 kHz Float32**. The library exposes `AudioConverter` (`Shared/AudioConverter.swift:91`) to resample any `URL` to 16 kHz Float32 mono.
- The manager **windows audio internally** based on `config.chunkDuration` (default 10 s, configurable) and `config.chunkOverlap` (default 0 s) — `DiarizerManager.swift:166-199`.
- The `atTime: TimeInterval` parameter is the offset of this audio's first sample in the larger meeting timeline. Use it when feeding chunks live (rebase per-chunk timestamps).

Output: `DiarizationResult` (`Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift:121`):

```swift
public struct DiarizationResult: Sendable {
    public let segments: [TimedSpeakerSegment]
    public let speakerDatabase: [String: [Float]]?    // populated only when config.debugMode = true
    public let timings: PipelineTimings?              // populated only when config.debugMode = true
}
public struct TimedSpeakerSegment: Sendable, Identifiable {
    public let id: UUID
    public let speakerId: String                      // e.g. "Speaker_1", or pre-enrolled name
    public let embedding: [Float]                     // 256-dim L2-normalized
    public let startTimeSeconds: Float
    public let endTimeSeconds: Float
    public let qualityScore: Float
    public var durationSeconds: Float { get }
}
```

Embedding dim: **256-dim WeSpeaker** (confirmed in `DiarizerManager.swift:78-91` doc-comment; the previous "384-dim" assumption is wrong for diarization — that was for the gte-small text embedding model in our own ARCHITECTURE.md, different system).

`speakerId` is a stable string — `SpeakerManager` keeps the same id across chunks for the same voice, so we can join on `speakerId` to label utterances in our transcript.

## 2.5 Clustering

**FluidAudio does the clustering for us.** Inside `performCompleteDiarization`, the `SpeakerManager` is invoked with `assignSpeaker(embedding, speechDuration:, confidence:)` and returns a stable speaker id (`DiarizerManager.swift:343-370`). We do **not** need to do any embedding clustering ourselves.

Configurable threshold: `DiarizerConfig.clusteringThreshold` (`DiarizerTypes.swift:9`):

```swift
public var clusteringThreshold: Float = 0.7      // 0.5 (more speakers) … 0.9 (fewer)
```

Down-stream, `SpeakerManager` derives two more thresholds from this (`DiarizerManager.swift:29-32`):

- speaker-assignment threshold = `clusteringThreshold * 1.2`
- embedding-update threshold   = `clusteringThreshold * 0.8`

## 2.6 Number of speakers

Auto-discovered. `DiarizerConfig.numClusters: Int = -1` (`DiarizerTypes.swift:21`). `-1` means automatic. We **can** pin it (e.g. `numClusters = 2`) for the golden 2-speaker test, but for live meetings leave the default.

## 2.7 Streaming / windowed inference

There is a streaming-friendly pattern but **not** a streaming API. The recipe (`Documentation/Diarization/GettingStarted.md:285-453`) is:

1. Keep one persistent `DiarizerManager` instance for the whole meeting (so `SpeakerManager` ids stay consistent).
2. Accumulate live mic audio into 5–10 s chunks in your own ring buffer (or use the `AudioStream` helper).
3. Call `performCompleteDiarization(chunk, atTime: chunkStartSec)` per chunk.
4. Append `result.segments` to the meeting timeline.

Key constraints (from `Documentation/Diarization/GettingStarted.md:381-398`):

- < 3 s chunks → unreliable.
- 3–5 s → minimum, lower accuracy.
- 10 s → recommended.
- > 10 s → fine, higher latency.

> The legacy `DiarizerManager` (Pyannote 3.1 segmentation + WeSpeaker embedding) is the slowest streaming option and the docs explicitly recommend `LSEENDDiarizer` or `SortformerDiarizer` for live use (`Documentation/Diarization/GettingStarted.md:9-13`). For Aftertalk's **offline post-meeting diarization** pass over the recorded audio, `DiarizerManager` is fine. If we ever want live "who is talking right now" for the recording UI, switch to Sortformer or LS-EEND (both also live in the same `FluidAudio` module — `SortformerDiarizer`, `LSEENDDiarizer`).

## 2.8 Compute units default

`DiarizerModels.defaultConfiguration()` (`DiarizerModels.swift:104-107`):

```swift
static func defaultConfiguration() -> MLModelConfiguration {
    let isCI = ProcessInfo.processInfo.environment["CI"] != nil
    return MLModelConfigurationUtils.defaultConfiguration(
        computeUnits: isCI ? .cpuAndNeuralEngine : .all
    )
}
```

> Default on a real device: `.all`. CI uses `.cpuAndNeuralEngine`. We can override by passing our own `MLModelConfiguration` to `DiarizerModels.download(configuration:)` or `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:configuration:)`. If we hit the same iOS 26 ANE bug as Kokoro, override with `.cpuAndGPU` here too.

## 2.9 Memory footprint

`Documentation/Diarization/GettingStarted.md:667`: "**~100 MB for Core ML models**" (combined segmentation + embedding bundle on disk). Runtime resident memory is not published; measure on device.

## 2.10 iOS 26 quirks

- `Documentation/Diarization/GettingStarted.md:192`: offline VBx pipeline requires "macOS 14 / iOS 17 or later" — we're well above that.
- No iOS 26-specific warnings in the diarizer source (unlike Kokoro). The underlying CoreML runtime is the same, so the same `.cpuAndGPU` workaround would apply if we hit the ANE compiler regression.

---

# 3. Reference: Canonical call snippets (verbatim from FluidAudio docs)

### Kokoro one-shot (`README.md:597-601`)

```swift
let manager = KokoroTtsManager()
try await manager.initialize()
let data = try await manager.synthesize(text: "Hello from FluidAudio.")
try data.write(to: URL(fileURLWithPath: "out.wav"))
```

### Kokoro with iOS 26 workaround (`KokoroTtsManager.swift:34-37`)

```swift
let manager = KokoroTtsManager(computeUnits: .cpuAndGPU)
try await manager.initialize()
```

### Diarizer one-shot (`Documentation/Diarization/GettingStarted.md:43-69`)

```swift
let models = try await DiarizerModels.downloadIfNeeded()
let diarizer = DiarizerManager()
diarizer.initialize(models: models)

let converter = AudioConverter()
let audioSamples = try converter.resampleAudioFile(url)   // 16 kHz mono Float32
let result = try await diarizer.performCompleteDiarization(audioSamples)

for segment in result.segments {
    print("Speaker \(segment.speakerId): \(segment.startTimeSeconds)s - \(segment.endTimeSeconds)s")
}
```

### Diarizer with pre-staged bundles (`Documentation/Diarization/GettingStarted.md:149-174`)

```swift
let basePath = "/path/to/speaker-diarization-coreml"
let segmentation = URL(fileURLWithPath: basePath).appendingPathComponent("pyannote_segmentation.mlmodelc")
let embedding    = URL(fileURLWithPath: basePath).appendingPathComponent("wespeaker_v2.mlmodelc")
let models = try await DiarizerModels.load(
    localSegmentationModel: segmentation,
    localEmbeddingModel: embedding
)
let diarizer = DiarizerManager()
diarizer.initialize(models: models)
```

### Diarizer streaming chunks (`Documentation/Diarization/GettingStarted.md:347-369`)

```swift
let diarizer = DiarizerManager()
diarizer.initialize(models: models)

var stream = AudioStream(
    chunkDuration: 5.0,
    chunkSkip: 2.0,
    streamStartTime: 0.0,
    chunkingStrategy: .useMostRecent
)
stream.bind { chunk, time in
    let results = try diarizer.performCompleteDiarization(chunk, atTime: time)
    for segment in results.segments { handleSpeakerSegment(segment) }
}
for audioSamples in audioStream { try stream.write(from: audioSamples) }
```

---

# 4. Summary cheat-sheet for implementation agents

| Question | Kokoro (`KokoroTtsManager`) | Diarizer (`DiarizerManager`) |
|---|---|---|
| SPM import | `import FluidAudio` | `import FluidAudio` |
| Top type | `public final class` | `public final class` |
| Sendable / actor | Neither (final class) | Neither (final class) |
| Construct | `KokoroTtsManager(computeUnits: .cpuAndGPU)` | `DiarizerManager(config: .default)` |
| Models loader | `TtsModels.download(...)` (auto) or implicit via `manager.initialize()` | `DiarizerModels.downloadIfNeeded()` or `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` |
| Initialize | `try await manager.initialize()` | `diarizer.initialize(models: models)` (sync, no `await`) |
| Inference call | `try await manager.synthesize(text:)` returns WAV `Data` | `try await diarizer.performCompleteDiarization(samples)` returns `DiarizationResult` |
| Sample rate I/O | Output 24 kHz mono 16-bit PCM WAV | Input 16 kHz mono Float32 |
| HF repo | `FluidInference/kokoro-82m-coreml` | `FluidInference/speaker-diarization-coreml` |
| Bundle filenames | `kokoro_21_5s.mlmodelc`, `kokoro_21_15s.mlmodelc` (+ G2P assets) | `pyannote_segmentation.mlmodelc`, `wespeaker_v2.mlmodelc` |
| Streaming | None (one-shot) | None (call per chunk; library does not yield AsyncStream) |
| Voice / speakers | `voice: String? = nil` (default `"af_heart"`) | Auto-clustered, ids `"Speaker_1"…` or pre-enrolled names |
| Cleanup | `manager.cleanup()` | `diarizer.cleanup()` |
| Default compute | `.all` (override `.cpuAndGPU` on iOS 26) | `.all` on device, `.cpuAndNeuralEngine` in CI |
| Memory on disk | ~325 MB (15s + 5s combined; both download by default) | ~100 MB |

---

# 5. RED FLAGS / OPEN QUESTIONS

These items the recon could **not** fully verify from the sources alone. Implementation agents should treat them as discovery tasks at integration time:

1. **Runtime resident memory on iPhone Air for Kokoro 15s variant.** Source exposes `variantFootprints` for on-disk size only. Need an Instruments run after `manager.initialize()` to measure peak working set. We need this for the privacy-pitch perf doc.

2. **First-token latency on iPhone Air at `.cpuAndGPU`.** The README quotes RTFx but not first-audio-byte latency. Important because Day 4 success is "answer playback starts within ~1 s of LLM stream first token." Measure on device.

3. **iOS 26 ANE compiler regression behavior.** The Kokoro doc says `.cpuAndGPU` is the workaround for "Cannot retrieve vector from IRValue format int32". Verify whether the same applies to **Diarizer** at iOS 26 — if `.all` crashes diarizer too, we need `.cpuAndGPU` for `DiarizerModels.download(configuration:)`.

4. **Behavior when sample-rate mismatch.** `performCompleteDiarization(_:sampleRate: 16000)` accepts the param but it's unclear whether the model itself does any internal resampling or just trusts the value for timestamp math. Safest path: always feed exactly 16 kHz Float32 via `AudioConverter`. (`DiarizerManager.swift:166-180` uses `sampleRate` only for index arithmetic — implies **no internal resample**.)

5. **WAV peak-normalization side effect for streaming TTS.** `AudioWAV.data` normalizes per call, so concatenating two `synthesize()` WAV outputs in a row will sound like a volume jump if peaks differ. To stream sentences cleanly we must use `synthesizeDetailed` and renormalize across the full utterance, **or** pipe the per-call `[Float]` straight into our `AVAudioEngine` mixer and let the engine handle gain. Confirm at integration which path the audio engine prefers.

6. **`KokoroTtsManager` Swift 6 strict-concurrency story.** The class isn't `Sendable` and uses internal `@TaskLocal` + `nonisolated(unsafe)` heavily. We must either pin all calls to a single isolation domain (e.g. our own `actor TTSService`) or accept warnings. Need an actual build to surface the warning set.

7. **`DiarizerManager.initialize(models:)` uses `consuming` ownership.** That means a `DiarizerModels` value can be moved in only once. If we want to re-initialize after `cleanup()`, we need to re-`download()` (or re-`load()`) the models. Cheap on disk (already cached) but not free. Document this in our `DiarizationService`.

8. **`af_heart` voice quality on a male speaker.** Voice is female. If we want a more neutral default for the demo, evaluate `af_nicole`, `am_michael`, `am_echo`. Only `af_heart` is the "regression-tested ship default" per `TtsConstants.swift:11`; anything else is "experimental" per the same file.

9. **Bundle download size on first launch.** `Repo.kokoro` resolves to a multi-variant download (5s + 15s + G2P + multilingual G2P). If we only ever use the 15s variant, pass `requestedVariants: [.fifteenSecond]` to `TtsModels.download` to halve the initial download. (`TtsModels.swift:46-54` — single-variant filter is supported.)

10. **`SortformerDiarizer` vs `DiarizerManager` for live UI.** Recon focused on the legacy `DiarizerManager` per the lock list. If we want a "live who is talking" indicator during recording, the docs recommend `SortformerDiarizer` (4-speaker max, 480 ms latency) or `LSEENDDiarizer` (10-speaker max, 100 ms latency) — both in the same `FluidAudio` module. Decision deferred to Day 4 implementation; the legacy diarizer is fine for the post-meeting batch pass.
