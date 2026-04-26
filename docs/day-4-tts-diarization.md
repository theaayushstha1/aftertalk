# Day 4 — Kokoro neural TTS + Pyannote diarization (Thu Apr 30)

## What you're building today
Replace AVSpeechSynthesizer with FluidAudio Kokoro 82M neural TTS for natural voice. Add Pyannote Core ML diarization so transcripts and summary include speaker labels (Sara, Mark, etc.). Streaming TTS pipelines sentence-by-sentence with prefetching.

## Worktree(s)
**Two parallel sessions today:**
- Session A: `~/Desktop/Aircaps-tts/` on `feat/kokoro-tts` (Kokoro integration)
- Session B: `~/Desktop/Aircaps-summary/` on `feat/summary-rag` (diarization wired into existing summary pipeline)

## Pre-flight checks
- [ ] Day 3 Q&A loop merged to `main`.
- [ ] FluidAudio repo skimmed: `https://github.com/FluidInference/FluidAudio`
- [ ] Kokoro 82M Core ML package downloaded
- [ ] Pyannote segmentation Core ML model downloaded

## Files this day touches

### Session A (Kokoro)
- **NEW** `Aftertalk/TTS/KokoroTTSService.swift` — implements `TTSService` protocol with Kokoro
- **NEW** `Aftertalk/TTS/TTSWorker.swift` — actor managing playback queue + prefetch
- **EDIT** `Aftertalk/QA/QAOrchestrator.swift` — swap `AVSpeechSynthesizer` for `KokoroTTSService`
- **EDIT** `Aftertalk/TTS/AudioSessionManager.swift` — add 24kHz Kokoro output handling

### Session B (Diarization)
- **NEW** `Aftertalk/Recording/DiarizationService.swift` — FluidAudio Pyannote wrapper
- **EDIT** `Aftertalk/Recording/AudioCaptureService.swift` — fan-out audio to ASR + diarization concurrently
- **EDIT** `Aftertalk/Persistence/Models/SpeakerLabel.swift` — store speaker centroids
- **EDIT** `Aftertalk/Summary/SummaryGenerator.swift` — include speaker context in system prompt
- **EDIT** `Aftertalk/UI/MeetingDetailView.swift` — render speaker color chips in transcript

## Dependencies to add
- **SPM**: `https://github.com/FluidInference/FluidAudio.git`
- **Bundled**: `kokoro-82m-int8.mlpackage`, `pyannote-segmentation.mlmodelc`

## Implementation order

### Session A: Kokoro
1. **FluidAudio SPM integration** (~30 min) — add package, import.
2. **KokoroTTSService** (~2 hrs)
   - Wrap FluidAudio Kokoro runner.
   - Input: text. Output: 24kHz PCM float32 buffer.
   - Cache the warmed-up model on first call.
3. **TTSWorker actor** (~2 hrs)
   - Queue of sentences.
   - Worker prefetches inference for sentence N+1 while N plays.
   - 50ms crossfade between adjacent player nodes.
4. **AVAudioPlayerNode integration** (~1 hr)
   - Convert 24kHz Kokoro PCM → 48kHz speaker output via `AVAudioConverter`.
   - Schedule buffers contiguously.
5. **Wire into QAOrchestrator** (~30 min) — swap `AVSpeechSynthesizer` for `KokoroTTSService`.

### Session B: Diarization
1. **FluidAudio Pyannote wrapper** (~2 hrs)
   - Streaming windowed inference (5-sec windows, 0.5-sec hop).
   - Output: array of `SpeakerSegment { speakerId, startSec, endSec, embedding }`.
2. **AudioCaptureService fan-out** (~1 hr)
   - Same audio buffer goes to both `MoonshineStreamer` and `DiarizationService`.
   - Use `AVAudioMixerNode` or just copy buffers in software (small enough).
3. **Speaker clustering** (~1.5 hrs)
   - Online clustering: each new segment compared to existing speaker centroids by cosine.
   - If max similarity > 0.7, assign to existing speaker; else create new.
   - Names: auto-assign "Speaker 1", "Speaker 2"; user can rename in UI.
4. **Summary prompt update** (~30 min)
   - Inject speaker name list into Foundation Models system prompt.
   - "Sara said …" attributions when extracting decisions/actions.
5. **UI: speaker color chips** (~1 hr) in transcript view.

## Verification
- [ ] Kokoro voice replaces robotic AVSpeechSynthesizer voice. Subjectively natural.
- [ ] TTFSW <1.5s on 17 Pro Max (with sentence-boundary streaming).
- [ ] 2-speaker meeting → 2 distinct speaker labels assigned in transcript with consistent IDs throughout.
- [ ] Summary action items attribute owner when speaker is identifiable.
- [ ] Q&A answer says "Sara said she'd handle the design review" instead of generic.
- [ ] Memory peak with Kokoro + Pyannote loaded: <600MB.

## Email home plate
- Neural TTS shipped: FluidAudio Kokoro 82M ANE-optimized. TTFSW now <1.5s on 17 Pro Max.
- Speaker diarization shipped: Pyannote Core ML, auto-labels speakers, summary attributes ownership.
- Two stretch goals down (#2 streaming Q&A and #4 neural TTS), three to go.
- Tomorrow: senior-grade VAD (TEN-VAD + SmartTurnV3) + cross-meeting memory.

## Demo prep
Capture: 2-speaker recording → show transcript with color-coded speakers → ask "what did <speaker A> commit to?" → Kokoro voice answers attributing correctly. Save to `~/Documents/Aftertalk/attachments/2026-04-30-tts-diarization-demo.mov`.

## If you get stuck
- **Kokoro inference too slow on Air**: use Kokoro 82M int8 quantized; ensure ANE compute units `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`.
- **First Kokoro inference takes 2s**: model warm-up. Prewarm at app launch with a dummy 1-word inference.
- **Pyannote misclassifies same speaker as two**: similarity threshold too tight; raise from 0.7 to 0.65.
- **AVAudioConverter crashes on 24kHz→48kHz**: confirm input format is `Float32` non-interleaved. Some Kokoro outputs are int16.
- **Speaker IDs flicker (same person labeled differently across windows)**: enable smoothing — require 3 consecutive windows agreement before changing label.

## End-of-day tasks
- [ ] Commit Session A: `feat(tts): FluidAudio Kokoro neural TTS with sentence-boundary streaming + prefetch`
- [ ] Commit Session B: `feat(diarization): Pyannote Core ML speaker labels in transcript and summary`
- [ ] Merge both branches into `main`.
- [ ] Append to `~/Documents/Aftertalk/10 — Daily Logs/2026-04-30 — Day 4.md`.
- [ ] Send email home plate.
