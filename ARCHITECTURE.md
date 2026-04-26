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

[User holds button] ──► [TEN-VAD + Moonshine ASR] ──► [Question text]
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
| ASR | Moonshine Swift (`moonshine-ai/moonshine-swift`) | Brief explicitly prefers Moonshine. 50ms TTFT tiny, native streaming arch, ONNX runtime | WhisperKit (Argmax) — production iOS package, ANE, sub-250ms |
| LLM | Apple Foundation Models (iOS 18+) | Free, ~30 tok/s on A17/A18, snapshot streaming + `@Generable` macros for structured output, RAG-friendly tool calling | MLX Swift + Phi-4-mini 4-bit |
| Embeddings | gte-small Core ML (384-dim) | Strong semantic recall, ~50MB, easy Core ML conversion | `NLContextualEmbedding` (Apple, free) as A/B comparator |
| Vector store | sqlite-vec on SwiftData SQLite file | Idiomatic Swift typed models, vector ops on same SQLite file, supports hierarchical scoping | VecturaKit (pure Swift) |
| TTS (stretch) | FluidAudio Kokoro 82M | ANE-optimized, 50x real-time, ~400ms first audio, single dependency that also ships diarization | `AVSpeechSynthesizer` if Kokoro integration explodes |
| Diarization (stretch) | FluidAudio Pyannote Core ML | Same dependency as TTS, ~80% accuracy on iPhone mic, 60x real-time | Skip + document tradeoff |
| VAD | TEN-VAD via Sherpa-ONNX | 40-50% faster than Silero v5, ~1MB, better short-silence detection | Silero v5 |
| EoU prediction | Pipecat SmartTurnV3 (ONNX, Sherpa) | Cuts 200-400ms perceived latency by predicting end-of-utterance from linguistic+prosodic patterns | 800ms silence timeout |

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
  embedding: Data              // 384*4 bytes for gte-small float32
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

`sqlite-vec` extension is loaded against the same SwiftData-backed SQLite file. Vector search runs as raw `MATCH` queries; results join back to SwiftData rows.

## Hierarchical 3-layer retrieval (cross-meeting memory)

Foundation Models hard cap: 4096 tokens (input + output). On iOS 26.4+ we get `Session.tokenCount(_:)` and `contextSize` for explicit budgeting, so we instrument every prompt.

### Token budget (Q&A turn)
- System prompt + tool definitions: ~250 tokens
- Question text: ~50 tokens
- Retrieved context: ≤2400 tokens (hard cap with truncation policy)
- Generation buffer: ~1200 tokens (assistant answer + safety margin)

### Pipeline
1. **Layer 1 — Summary search**: query embedded (gte-small 384-dim) → cosine match against `MeetingSummaryEmbedding` → top-K=5 meetings.
2. **Layer 2 — Chunk search**: query → `TranscriptChunk` rows scoped to those 5 meetings → top-K=8 chunks.
3. **Layer 3 — ContextPacker assembly**: render each chunk as `[meeting_title • HH:MM • speaker_label] chunk_text`. Tokenize cumulatively. Stop adding chunks when budget hits 2400 tokens. Cite chunk IDs in the response so the UI can highlight source spans.

**Per-meeting Q&A** skips Layer 1 (forced `meeting_id` filter), keeps Layer 2 + 3.

**Speaker labels in Q&A answers**: when chunks come from diarized segments, the LLM is instructed via system prompt to attribute claims (`"Sara said …"`, `"Mark committed to …"`). Citations carry speaker IDs through.

**Failure mode (grounding gate, from CS Navigator v5)**: if hierarchical retrieve returns zero chunks above similarity threshold (cold-start or off-topic question), respond "I don't have that in the meeting transcripts" rather than hallucinate.

## VAD + turn-taking + barge-in

Three layers:

**Layer 1 — TEN-VAD** (Tencent, 40-50% faster than Silero v5, ~1MB, ONNX via Sherpa-ONNX). Output: `isSpeaking` boolean at 30ms granularity.

**Layer 2 — Pipecat SmartTurnV3 EoU prediction**. Transformer that predicts turn-end 200-500ms before raw silence completes. Trigger response when `VAD_p > 0.95 AND EoU_p > 0.80`.

**Layer 3 — Hold-to-talk override**. User can always hold the button; release = immediate finalize. EoU is for hands-free auto mode.

### Barge-in flow (with AEC discipline)
1. While TTS plays, mic stays armed, AEC active (Apple's voice-processing IO unit).
2. If TEN-VAD reports speech for ≥150ms continuous AND that audio passes ASR confidence threshold:
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
- TEN-VAD detection: 30ms
- EoU prediction trigger: 80ms
- ASR finalize (Moonshine): 150ms
- Hierarchical retrieve: 50ms
- Foundation Models first token: 33ms
- Sentence boundary buffer + Kokoro first audio: ~400ms
- **Total perceived TTFSW: ~750ms** (brief target was sub-3s; we beat it 4x)

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
│   ├── AudioCaptureService.swift     // AVAudioEngine + concurrent ASR/diarization taps
│   ├── MoonshineStreamer.swift       // wraps moonshine-swift, emits TranscriptDelta
│   ├── DiarizationService.swift      // FluidAudio Pyannote, emits SpeakerSegment
│   ├── VADService.swift              // TEN-VAD via Sherpa-ONNX, isSpeaking events
│   └── RecordingViewModel.swift
├── Summary/
│   ├── SummaryGenerator.swift        // Foundation Models @Generable struct call
│   ├── MeetingSummary.swift          // {decisions, actions, topics, openQs}
│   └── ChunkIndexer.swift            // splits transcript into chunks, runs gte-small embeddings
├── Retrieval/
│   ├── EmbeddingService.swift        // gte-small Core ML wrapper
│   ├── VectorStore.swift             // sqlite-vec query layer
│   ├── HierarchicalRetriever.swift   // 3-layer scope logic
│   └── ContextPacker.swift           // prompt assembly with citations + token budgeting
├── QA/
│   ├── QAOrchestrator.swift          // ties ASR → retrieve → LLM → TTS
│   ├── BargeInController.swift       // VAD-driven interrupt + cancel
│   ├── SentenceBoundaryDetector.swift
│   └── ChatThreadView.swift
├── TTS/
│   ├── KokoroTTSService.swift        // FluidAudio Kokoro wrapper, streaming queue
│   ├── TTSWorker.swift               // actor managing playback + prefetch
│   └── AudioSessionManager.swift     // .playAndRecord + ducking config
├── Persistence/
│   ├── ModelContainer+Aftertalk.swift
│   ├── SQLiteVecBootstrap.swift      // loads sqlite-vec extension on app launch
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
