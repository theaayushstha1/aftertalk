# Aftertalk — Architecture

Technical reference. Read after `CLAUDE.md` and `PRD.md`. The `~/Documents/Aftertalk/02 — Architecture.md` Obsidian note mirrors this file with `[[wikilinks]]` for personal navigation.

## Pipeline overview
```
[AVAudioEngine mic] ─┬─► [Moonshine ASR streaming] ──► [Transcript chunks]
                     │                                       │
                     └─► [Pyannote diarization (Core ML)] ───┤
                                                              ▼
                                          [Foundation Models structured summary]
                                                              │
                                                              ▼
                                                    [Meeting record + index]

[User holds button] ──► [Energy gate + Moonshine ASR] ──► [Question text]
                                                       │
                                                       ▼
                            [Hierarchical retrieval: summary index → meeting chunk index]
                                                       │
                                                       ▼
                                  [Foundation Models snapshot streaming]
                                                       │
                                                       ▼
                                  [Sentence boundary detector → TTS queue]
                                                       │
                                                       ▼
                                          [Kokoro neural TTS via FluidAudio]
                                                       │
                                                       ▼
                                   [Speaker output, with barge-in mic active]
```

## Component decisions

| Layer | Pick | Why | Fallback |
|---|---|---|---|
| ASR (live) | Moonshine **medium streaming** (`moonshine-ai/moonshine-swift`) via `EnergyVADGate` | Best WER in the Moonshine family at acceptable iPhone footprint; the VAD gate sheds 40–60% of input compute on conversational silence so medium fits inside real-time on A18 hardware | WhisperKit (Argmax) — production iOS package, ANE, sub-250ms |
| ASR (post-recording polish) | FluidAudio **Parakeet TDT 0.6B v2** (Core ML) | Word-level timings, lower WER than streaming Moonshine at the cost of being non-streaming | Skip and ship raw Moonshine streaming output |
| LLM | Apple Foundation Models (iOS 26+) | Free, ~30 tok/s on A18, snapshot streaming + `@Generable` macros for structured output, RAG-friendly tool calling | MLX Swift + Phi-4-mini 4-bit |
| Embeddings | Apple **NLContextualEmbedding** (system asset, 512-dim, English) | Zero bytes shipped in the bundle, on-device, hands a Float vector per token straight to our `EmbeddingService` protocol | gte-small Core ML (384-dim, ~50 MB) — researched + deferred until A/B harness shows recall@3 lift justifies the bundle weight |
| Vector store | **SwiftDataVectorStore** — typed `MeetingSummaryEmbedding` rows + in-process cosine search | Idiomatic SwiftData; the cosine pass is O(n·d) but n stays in the hundreds for the take-home corpus and dimensionality is 512 | sqlite-vec on the same SQLite file — researched + deferred until meeting count climbs into the tens |
| TTS (stretch) | FluidAudio Kokoro 82M | ANE-optimized, 50x real-time, ~400ms first audio, single dependency that also ships diarization | `AVSpeechSynthesizer` if Kokoro integration explodes |
| Diarization (stretch) | FluidAudio Pyannote Core ML | Same dependency as TTS, ~80% accuracy on iPhone mic, 60x real-time | Skip + document tradeoff |
| VAD | `EnergyVADGate` — RMS hysteresis, -38 / -50 dBFS thresholds, 300 ms hold tail, 200 ms pre-roll. Sheds silence frames before they reach Moonshine so medium streaming holds real-time on iPhone. | Energy-based today; the gate's `RecordingProfile`-driven init is wired so a future Classroom Mode commit can swap to far-field thresholds without touching the gate's call sites | TEN-VAD via Sherpa-ONNX (researched, deferred to hardening sprint) |
| EoU prediction | 800ms silence timeout + hold-to-talk override | Hold-to-talk covers the demo flow; auto-EoU is not on the critical path | Pipecat SmartTurnV3 (researched, deferred to hardening sprint) |

## SwiftData data model

```swift
@Model class Meeting {
  id: UUID
  title: String
  recordedAt: Date
  durationSeconds: Double
  audioURL: URL
  fullTranscript: String
  summary: MeetingSummary?     // structured: decisions, actions, topics, openQs
  speakers: [SpeakerLabel]
  chunks: [TranscriptChunk]    // chunked for retrieval
  chats: [ChatThread]          // 1 per-meeting thread
}

@Model class TranscriptChunk {
  id: UUID
  meetingId: UUID
  text: String
  startSec: Double
  endSec: Double
  speakerId: UUID?
  embedding: Data              // 512*4 bytes for NLContextualEmbedding float32
}

@Model class SpeakerLabel {
  id: UUID
  meetingId: UUID
  displayName: String          // "Sara", "Mark"; user-editable
  color: String                // hex
  embeddingCentroid: Data
}

@Model class MeetingSummaryEmbedding {
  meetingId: UUID
  embedding: Data              // one vector per meeting for top-K filtering
}

@Model class ChatThread {
  id: UUID
  meetingId: UUID?             // nil ⇒ global cross-meeting thread
  isGlobal: Bool
  messages: [Message]
}

@Model class Message {
  id: UUID
  threadId: UUID
  role: String                 // "user" | "assistant"
  text: String
  audioURL: URL?
  timestamp: Date
  citations: [ChunkRef]
}
```

Vector search runs in-process on `SwiftDataVectorStore` — `MeetingSummaryEmbedding` and `TranscriptChunk.embedding` are loaded into Float arrays and scored with cosine similarity. The sqlite-vec route was researched and is the planned upgrade once meeting count climbs into the tens; for the take-home corpus the in-process pass stays well under 5 ms.

## Hierarchical 3-layer retrieval (cross-meeting memory)

Foundation Models hard cap: 4096 tokens (input + output). On iOS 26.4+ we get `Session.tokenCount(_:)` and `contextSize` for explicit budgeting, so we instrument every prompt.

### Token budget (Q&A turn)
- System prompt + tool definitions: ~250 tokens
- Question text: ~50 tokens
- Retrieved context: ≤2400 tokens (hard cap with truncation policy)
- Generation buffer: ~1200 tokens (assistant answer + safety margin)

### Pipeline
1. **Layer 1 — Summary search**: query embedded (`NLContextualEmbedding`, 512-dim) → cosine match against `MeetingSummaryEmbedding` → top-K=5 meetings.
2. **Layer 2 — Chunk search**: query → `TranscriptChunk` rows scoped to those 5 meetings → top-K=8 chunks.
3. **Layer 3 — ContextPacker assembly**: render each chunk as `[meeting_title • HH:MM • speaker_label] chunk_text`. Tokenize cumulatively. Stop adding chunks when budget hits 2400 tokens. Cite chunk IDs in the response so the UI can highlight source spans.

**Per-meeting Q&A** skips Layer 1 (forced `meeting_id` filter), keeps Layer 2 + 3.

**Speaker labels in Q&A answers**: when chunks come from diarized segments, the LLM is instructed via system prompt to attribute claims (`"Sara said …"`, `"Mark committed to …"`). Citations carry speaker IDs through.

**Failure mode (grounding gate, from CS Navigator v5)**: if hierarchical retrieve returns zero chunks above similarity threshold (cold-start or off-topic question), respond "I don't have that in the meeting transcripts" rather than hallucinate.

## VAD + turn-taking + barge-in

**Shipped today:** `EnergyVADGate` with -38 / -50 dBFS thresholds, 300 ms hold tail, 200 ms pre-roll. Hold-to-talk is the only auto-interrupt mechanism. Industry-standard upgrade is **Silero v5**; **TEN-VAD + Pipecat SmartTurnV3** were researched and deferred to the hardening sprint after Nirbhay's Day 5 review (the energy gate misfires on Kokoro tail bleed past Apple's AEC and the auto-rearm path then opens a 6 s mic window that ASR happily transcribes — see `Aftertalk/QA/BargeInController.swift` and `QAOrchestrator.swift` for the canonical comments).

**Layer 1 — Silero v5 (planned) / energy gate (shipped)**. RMS threshold + hold time on the captured 16 kHz frames. Output: `isSpeaking` boolean.

**Layer 2 — 800 ms silence timeout for end-of-utterance**. Pipecat SmartTurnV3 transformer (predicts turn-end 200-500ms before raw silence completes via linguistic+prosodic features) is documented as the future swap; not on the demo path.

**Layer 3 — Hold-to-talk override**. User can always hold the button; release = immediate finalize. This is the only auto-interrupt mechanism in the shipped build.

### Barge-in flow (with AEC discipline)
1. While TTS plays, mic stays armed, AEC active (Apple's voice-processing IO unit).
2. Auto barge-in is intentionally disabled in the shipped build (see `BargeInController.swift`); user taps to stop. When Silero v5 (or TEN-VAD as the deferred research option) lands and the energy gate is replaced, the flow becomes: VAD reports speech for ≥150ms continuous AND that audio passes ASR confidence threshold:
   - Hard-stop Kokoro audio via `AVAudioPlayerNode.stop()` + 50ms fade
   - Cancel in-flight Foundation Models generation (cooperative cancellation token)
   - Drop unspoken sentence buffer
   - Begin recording new question

## iOS audio session pitfall checklist

- Configure session in this order: `.playAndRecord` category → `.voiceChat` mode → `setPrefersEchoCancelledInput(true)` → activate. Wrong order silently disables AEC.
- Use `AVAudioEngine` with VoiceProcessingIO audio unit (not raw mic input) for built-in AEC. Apple's AEC is sufficient on iPhone 12+; do not pull in WebRTC AEC unless you have ≥20ms timing requirements.
- After `AVAudioPlayerNode.stop()`, the next `installTap` produces 100-200ms of garbage audio. Workaround: 100ms guard delay before resuming ASR, or reinitialize the audio graph.
- Sample rate management is explicit: mic delivers 48kHz, ASR wants 16kHz, Kokoro outputs 24kHz, speaker wants 48kHz. Use `AVAudioConverter` at every boundary; never rely on implicit graph conversion.
- Register `AVAudioSession.interruptionNotification` and handle `.shouldResume` (Siri, calls, notifications). Failing to resume = mic hot, speaker silent.
- Do NOT deactivate the session while I/O is running (`stop()` all nodes first). Common deadlock.
- AirPods + `.voiceChat` adds 80-150ms via SBC codec. Demo video uses wired or speaker.

## Latency budget (iPhone 17 Pro Max target)

The brief asks for sub-3 s time-to-first-spoken-word. The exact number
the shipped pipeline achieves is **pending re-measure** after the
late-week VAD-gated streaming + Q&A tail-silence work — the prior
budget here was based on a researched-but-not-shipped architecture
(TEN-VAD + Pipecat SmartTurnV3) and a measurement of an older code
path. Rather than carry stale numbers forward, the in-process
`SessionPerfSampler` writes a per-session CSV at every recording so a
clean number ships with the submission tag, not with this doc.

For the rough cost breakdown of where the budget goes, see the
`QAOrchestrator` source — `ttfswMillis` is documented inline as the
moment-the-user-released-the-mic to first-sentence-handed-to-synth
(Kokoro adds another ~250–300 ms before audio actually leaves the
speaker, which we don't fold into the metric because FluidAudio
doesn't expose a first-chunk callback yet).

## Streaming Q&A pipeline
```
Foundation Models stream
  → snapshot updates arrive every ~30ms
  → SentenceBoundaryDetector consumes, emits completed sentences (split on .!? + length-clamping fallback at 80 chars)
  → SentenceQueue (actor) hands sentences to TTSWorker
  → TTSWorker preloads Kokoro inference for sentence N+1 while sentence N plays
  → AVAudioPlayerNode plays sequentially with 50ms crossfade
```

## Project file structure

```
Aftertalk/
├── App/
│   ├── AftertalkApp.swift            // @main, app lifecycle, model container
│   └── RootView.swift                // tab nav: Meetings | Global Chat | Settings
├── Onboarding/
│   ├── OnboardingFlow.swift          // 3-screen privacy-first onboarding
│   └── AirplaneModeCheck.swift       // toggles Network monitor, shows green badge
├── Recording/
│   ├── AudioCaptureService.swift     // AVAudioEngine + 48k→16k AVAudioConverter + WAV writer
│   ├── AudioPreprocessor.swift       // 6 dB linear gain + tanh soft-clip for far-field ASR conditioning
│   ├── EnergyVADGate.swift           // RMS hysteresis + pre-roll + hold-tail; sheds silence frames
│   ├── MoonshineStreamer.swift       // wraps moonshine-swift, emits TranscriptDelta
│   ├── BatchASRService.swift         // post-recording polish router (Parakeet → Moonshine fallback)
│   ├── FluidAudioParakeetTranscriber.swift  // FluidAudio Parakeet TDT 0.6B v2, word timings
│   ├── PyannoteDiarizationService.swift     // FluidAudio Pyannote 3.1 + WeSpeaker v2
│   ├── ModelLocator.swift            // bundle / Application Support model path resolution
│   └── RecordingViewModel.swift
├── Summary/
│   ├── SummaryGenerator.swift        // Foundation Models @Generable struct call
│   ├── MeetingSummary.swift          // {decisions, actions, topics, openQs}
│   ├── DiarizationReconciler.swift   // aligns ASR word timings to speaker segments
│   ├── MeetingProcessingPipeline.swift  // orchestrates polish → diarize → chunk → embed → summarize
│   └── ChunkIndexer.swift            // 4-sentence windows + 1-sentence overlap
├── Retrieval/
│   ├── EmbeddingService.swift        // NLContextualEmbedding wrapper (512-dim, English)
│   ├── VectorStore.swift             // SwiftDataVectorStore — typed rows + in-process cosine
│   ├── HierarchicalRetriever.swift   // 3-layer scope logic
│   └── ContextPacker.swift           // prompt assembly with citations + token budgeting
├── QA/
│   ├── QAOrchestrator.swift          // ties ASR → retrieve → LLM → TTS, threads honest TTFSW
│   ├── QuestionASR.swift             // hold-to-talk question recorder + tail-silence bookend
│   ├── BargeInController.swift       // wired but disabled — see "turn-taking" row in README table
│   ├── SentenceBoundaryDetector.swift
│   └── ChatThreadView.swift
├── TTS/
│   ├── KokoroTTSService.swift        // FluidAudio Kokoro 82M wrapper, streaming queue
│   ├── TTSWorker.swift               // actor managing playback + prefetch
│   └── AudioSessionManager.swift     // .playAndRecord + .voiceChat AEC plumbing
├── Persistence/
│   ├── ModelContainer+Aftertalk.swift
│   ├── MeetingsRepository.swift      // @ModelActor — meetings, embeddings, chats, delete cleanup
│   └── Models/                       // SwiftData @Model files
├── UI/
│   ├── MeetingsListView.swift
│   ├── MeetingDetailView.swift       // transcript + summary + chat
│   ├── GlobalChatView.swift          // cross-meeting thread
│   ├── RecordButton.swift            // animated waveform + record state
│   └── DesignSystem.swift            // colors, typography, spacing tokens
└── Profiling/
    ├── PerfMonitor.swift             // MetricKit + custom timestamps
    └── PerfReportExporter.swift      // dump CSV + matplotlib-compatible
```

## Patterns reused from CS Navigator v5

| Pattern | CS Navigator | Aftertalk |
|---|---|---|
| Grounding gate | 0 KB chunks → disclaimer | 0 chunks above sim threshold → "I don't have that in the meeting transcripts" |
| 3-layer follow-up resolver | regex → entity → LLM | "what did she commit to?" resolves "she" from previous assistant turn's cited speaker |
| Course Context Engine | pre-computed advisor cards | pre-computed speaker cards + topic cards at summary-generation time |
| Failed query pipeline | log + cluster + research | low-confidence Q&A log → Settings → "Questions I struggled with" |
| Multi-account skill design | one surface, multiple personas | meeting-as-account threading model |

## Known tradeoffs (called out in README)
1. **iPhone Air slower than 17 Pro Max** by ~30% on Foundation Models throughput. We tune the budget on Air; demo video uses 17 Pro Max for tightest TTFSW.
2. **Kokoro voice is single-language English**. Out-of-scope for take-home.
3. **Pyannote on iPhone mic** ~80% diarization accuracy. Demo uses 2-speaker recordings; >2 speakers degrades visibly.
4. **Foundation Models 4K cap** forces hierarchical RAG. Long meetings (>30min) compress less faithfully. Documented in README's "What I'd build with another two weeks."
