# Day 5 — Senior-grade VAD + barge-in + cross-meeting memory (Fri May 1)

## What you're building today
Two big items, two parallel worktrees:

1. **VAD + barge-in**: TEN-VAD replaces silence-timeout, Pipecat SmartTurnV3 EoU prediction trims 200-400ms perceived latency, barge-in interrupts TTS within 150ms of user starting to speak. This is the "Gemini Live" feel.
2. **Cross-meeting memory**: hierarchical 3-layer retrieval activates Layer 1 (summary search across all meetings). Global chat thread (no `meetingId`) lets user ask "what has Sara committed to overall?" across history.

## Worktree(s)
- Session A: `~/Desktop/Aircaps-vad/` on `feat/vad-bargein`
- Session B: `~/Desktop/Aircaps-qa/` on `feat/qa-loop` (continued)

## Pre-flight checks
- [ ] Day 4 merged to main, Kokoro + Pyannote shipped.
- [ ] Sherpa-ONNX iOS framework added (handles ONNX models for VAD + EoU).
- [ ] TEN-VAD ONNX model downloaded.
- [ ] Pipecat SmartTurnV3 ONNX model downloaded.

## Files this day touches

### Session A (VAD + Barge-in)
- **NEW** `Aftertalk/Recording/VADService.swift` — TEN-VAD via Sherpa-ONNX
- **NEW** `Aftertalk/Recording/EoUPredictor.swift` — SmartTurnV3 via Sherpa-ONNX
- **NEW** `Aftertalk/QA/BargeInController.swift` — VAD-driven interrupt + cancellation
- **EDIT** `Aftertalk/QA/QAOrchestrator.swift` — wire BargeIn cancellation token
- **EDIT** `Aftertalk/TTS/TTSWorker.swift` — support hard-stop with 50ms fade
- **EDIT** `Aftertalk/TTS/AudioSessionManager.swift` — keep mic armed during TTS playback

### Session B (Cross-meeting memory)
- **NEW** `Aftertalk/UI/GlobalChatView.swift` — cross-meeting chat thread UI
- **EDIT** `Aftertalk/Retrieval/HierarchicalRetriever.swift` — implement Layer 1 (summary search)
- **EDIT** `Aftertalk/Summary/ChunkIndexer.swift` — generate `MeetingSummaryEmbedding` after summary done
- **EDIT** `Aftertalk/QA/QAOrchestrator.swift` — switch retrieval mode based on `isGlobal` thread
- **EDIT** `Aftertalk/App/RootView.swift` — add Global Chat tab

## Dependencies to add
- **SPM**: `https://github.com/k2-fsa/sherpa-onnx.git` iOS bindings
- **Bundled**: `ten-vad.onnx`, `smart-turn-v3.onnx`

## Implementation order

### Session A: VAD + Barge-in
1. **Sherpa-ONNX iOS integration** (~1.5 hr)
   - Add framework, import.
   - Wrap a generic `ONNXRuntime` Swift type for both VAD and EoU.
2. **TEN-VAD streaming wrapper** (~1.5 hr)
   - Input: 16kHz PCM 30ms frames.
   - Output: `isSpeaking: Bool` per frame.
3. **EoU predictor** (~1.5 hr)
   - Input: last 1s of audio.
   - Output: `eouProbability: Float`.
   - Run every 100ms while speaking.
4. **BargeInController** (~2 hrs)
   - State machine: `.idle | .userSpeaking | .assistantSpeaking | .interrupted`.
   - During `.assistantSpeaking`: monitor VAD. If `isSpeaking` for ≥150ms continuous, hard-stop TTS, cancel LLM, return to `.userSpeaking`.
   - During `.userSpeaking`: trigger response when `VAD_p > 0.95 AND EoU_p > 0.80` (auto mode), or on hold-button release (manual mode).
5. **Audio session refinements** (~1 hr)
   - Confirm AEC active when both mic and speaker are running.
   - Test on speaker output (NOT AirPods) to avoid SBC codec latency.
6. **Wire cancellation tokens** (~30 min)
   - Foundation Models session supports cooperative cancellation via `Task` cancellation.
   - TTSWorker's `cancelAll()` clears queue + stops player nodes with 50ms fade.

### Session B: Cross-meeting memory
1. **MeetingSummaryEmbedding generation** (~1 hr)
   - After summary generation, embed the summary text (truncated to 1500 chars) and store.
2. **Hierarchical retrieve Layer 1** (~1.5 hrs)
   - Query → embed → cosine match against `MeetingSummaryEmbedding` → top-K=5 meetings.
   - Pass meetingIds to Layer 2.
3. **Layer 2 update** (~30 min)
   - Scope chunk search to those 5 meetings instead of single meeting.
4. **GlobalChatView UI** (~2 hrs)
   - Looks like per-meeting chat but with citation pills showing source meeting title.
   - "Cross-meeting" badge in header.
5. **Routing** (~30 min)
   - QAOrchestrator checks `chatThread.isGlobal` → uses Layer 1+2; else single-meeting Layer 2 only.

## Verification

### VAD + Barge-in
- [ ] Talking immediately after assistant starts speaking → TTS stops within 150ms, mic captures new question.
- [ ] Auto mode: ask question without holding button — when you stop speaking, response triggers within 100ms (EoU prediction).
- [ ] No false barge-in from TTS audio leaking through speaker (AEC working).
- [ ] Cancellation propagates through LLM stream, no zombie generation.

### Cross-meeting
- [ ] Record 3 short meetings with overlapping topics (Sara appears in all 3).
- [ ] Global chat: "what has Sara committed to overall?" → answer cites chunks from all 3 meetings.
- [ ] Latency for global query <2.5s end-to-end (extra 50ms vs per-meeting due to Layer 1).

## Email home plate
- Senior-grade VAD shipped: TEN-VAD + Pipecat SmartTurnV3 EoU prediction. TTFSW now ~750ms on 17 Pro Max (4x better than brief target).
- Barge-in: TTS interrupts within 150ms of user speaking, with AEC discipline.
- Cross-meeting memory live: hierarchical 3-layer retrieval, global chat thread.
- Tomorrow: polish, profiling, edge cases.

## Demo prep
Capture: ask question, while assistant is mid-answer, interrupt with new question → assistant stops cleanly, addresses new question. Capture global chat: 3 meetings, cross-meeting question with citations from each. Save to `~/Documents/Aftertalk/attachments/2026-05-01-vad-cross-meeting-demo.mov`.

## If you get stuck
- **Sherpa-ONNX iOS framework size bloat**: use the static-link variant or strip unused ops; the full lib is ~30MB.
- **TEN-VAD false positives from TTS leak**: tighten AEC, lower mic gain during TTS, or add a 100ms "echo guard" delay after each TTS sentence ends before re-arming VAD.
- **EoU prediction never fires**: input format wrong; SmartTurnV3 expects mel-spectrogram not raw PCM. Check repo's preprocessor code.
- **Cross-meeting Layer 1 misses obvious matches**: summary embedding is too abstract; embed `summary.decisions + summary.topics` joined as a single string instead of full summary.
- **Citations across meetings overflow context budget**: tighten Layer 2 top-K from 8 to 5 when in global mode.

## End-of-day tasks
- [ ] Commit Session A: `feat(vad): TEN-VAD + SmartTurnV3 EoU + barge-in with AEC discipline`
- [ ] Commit Session B: `feat(memory): hierarchical 3-layer retrieval + global cross-meeting chat`
- [ ] Merge both branches into `main`.
- [ ] Append to `~/Documents/Aftertalk/10 — Daily Logs/2026-05-01 — Day 5.md`.
- [ ] Send email home plate.
