# Aftertalk — Claude Code Session Rules

You are working on **Aftertalk**, a fully on-device iOS meeting recording + voice Q&A app. This is a take-home for **AirCaps (YC F25)** that gates an in-person paid work trial. There is no fixed deadline — the project runs until Aayush is satisfied with submission quality.

## What this app does
Records a meeting on iPhone in airplane mode → streams ASR locally → generates a structured summary on-device → user holds a button, asks a question by voice → app retrieves from the meeting (or across all meetings) and answers by voice. No network calls, ever. iOS 26+, Swift 6, primary devices iPhone Air + iPhone 17 Pro Max.

## Hard invariants (do not violate)
1. **No network calls in production code paths.** No `URLSession`, no `URLRequest`, no third-party SDK that phones home. Privacy is the entire pitch.
2. **iOS 26+ only.** Foundation Models was introduced at WWDC25 and ships with iOS 26. Do not add iOS 18 fallbacks.
3. **Foundation Models context cap is 4096 tokens.** Always budget: ~250 system + ~50 question + ≤2400 context + ~1200 generation. Use `Session.tokenCount(_:)` (iOS 26.4+) to verify.
4. **Audio session transitions are sacred.** Recording/question capture uses measurement-quality input; Kokoro playback uses `.playback` + `.spokenAudio`. Only use `.voiceChat` AEC if auto barge-in is re-enabled, and then configure category → mode → `setPrefersEchoCancelledInput(true)` → activate.
5. **Sample rate conversion is explicit.** Mic 48kHz → ASR 16kHz → Kokoro 24kHz → speaker 48kHz. Never rely on implicit graph conversion.
6. **Test on device, not simulator.** ANE is unavailable in simulator; perf claims must come from iPhone Air or 17 Pro Max.

## Component picks (locked, do not bikeshed)
| Layer | Pick | Fallback |
|---|---|---|
| ASR | Moonshine small streaming live preview + Parakeet polish | Moonshine medium for short controlled demos; WhisperKit researched |
| LLM | Apple Foundation Models | MLX Swift + Phi-4-mini |
| Embeddings | Apple NLContextualEmbedding (512-dim) | gte-small Core ML if A/B proves recall lift |
| Vector store | SwiftDataVectorStore in-process cosine | sqlite-vec / VecturaKit when corpus grows |
| TTS | FluidAudio Kokoro 82M | AVSpeechSynthesizer |
| Diarization | FluidAudio Pyannote Core ML | skip + document |
| VAD | Silero v5 (industry-standard pick) — currently shipping energy-based gate as bridge | TEN-VAD via Sherpa-ONNX (researched, deferred to hardening sprint) |
| Turn detection | Hold-to-talk; auto barge-in intentionally disabled | Pipecat SmartTurnV3 (researched, deferred to hardening sprint) |

## Session workflow
1. On session start, read in this order: `CLAUDE.md` (this file) → `PRD.md` → `ARCHITECTURE.md` → the relevant `docs/day-N-*.md` for the worktree you're in.
2. Check `git status` and `git branch` to confirm which worktree/branch you're on.
3. Pick up the day brief's "next step" and execute. Mark items done in the brief as you go.
4. Before claiming a feature complete: build to a real device, run the verification checklist in the day brief, paste perf numbers into `perf/`.
5. End of session: commit with conventional-commits prefix (`feat:`, `fix:`, `chore:`, `docs:`, `perf:`), push to the feature branch.
6. **End of session, mandatory**: append today's progress to `~/Documents/Aftertalk/10 — Daily Logs/<today>.md` (the personal Obsidian vault, NOT an app feature). See "Obsidian vault update" below.

## Device log monitoring protocol

When Aayush signals he's about to test on device — phrases like **"I will test it now"**, **"testing it now"**, **"let me test"**, **"about to record"**, **"starting a recording"** — start streaming device logs in the background BEFORE he taps Record so we capture the full session.

```bash
# Start background log stream filtered for Aftertalk + FluidAudio + Moonshine.
# `idevicesyslog` requires libimobiledevice (`brew install libimobiledevice`).
idevicesyslog -p Aftertalk 2>&1 \
  | grep -iE "aftertalk|fluidaudio|moonshine|diariz|kokoro|capture|asr|router|grounding|ttfsw|warm|stop#|start#|collapse" \
  > /tmp/aftertalk-device.log &
```

Use `Bash` with `run_in_background: true`, capture the shell ID, then read `/tmp/aftertalk-device.log` after the user reports the test is done.

**Honest limitation**: `idevicesyslog` reads from the legacy ASL stream, not iOS unified logging. So:
- ✅ Captured: stdio `print()` (our `Audio capture started:` lines, `Moonshine session started` lines, `[BUILD-V3]` debug prints), and FluidAudio's `[FluidAudio.X]` formatted lines
- ❌ NOT captured: anything emitted via Apple's `Logger` / `os_log` (our `subsystem: "com.theaayushstha.aftertalk"` calls — `Diarization`, `VM`, `QA`, `Pipeline` categories)

If the test exercises a code path whose key signal lives in `Logger` output (e.g. the new `collapse:` lines in diarization post-processing), tell Aayush up front: *"I'll stream what `idevicesyslog` can catch. The `collapse:` line uses `Logger`, so if I don't see it, paste the Xcode console output and I'll work from that."*

After the test:
1. `kill <shell_id>` (or just let the background tool stop on its own)
2. Read `/tmp/aftertalk-device.log` and analyze
3. If the relevant signal didn't appear, ask Aayush for the Xcode console paste

Don't pre-launch the stream until Aayush signals testing — running `idevicesyslog` constantly fills `/tmp` and burns battery on the phone.

## Coding conventions
- Swift 6 strict concurrency mode. All cross-actor state passes through `@MainActor` or actor isolation.
- One feature = one folder under `Aftertalk/`. No god-files.
- Public API on each service is a protocol (`ASRService`, `TTSService`, `LLMService`, `EmbeddingService`, `VectorStore`). Concrete impls behind protocols so we can swap fallbacks in <5 min.
- No singletons except `ModelContainer` and `AudioSessionManager`. Inject via initializers.
- Error type per module (`ASRError`, `TTSError`, ...). Surface to UI with user-readable copy.
- All async work uses `Task` + structured concurrency. No `DispatchQueue.global` unless wrapping a C API.
- Performance-critical loops (ASR sample buffer, Kokoro inference) get `@inlinable` + `@frozen` annotations and a comment explaining why.

## Testing rules
- Unit tests for `SentenceBoundaryDetector`, `ContextPacker`, `HierarchicalRetriever`, `SpeakerLabeler`. Deterministic IO, safe to mock.
- Snapshot test for the `MeetingSummary` `@Generable` schema — input is the golden 5-min synthetic 2-speaker meeting, assertions are decisions/actions exact-match.
- No mocked audio for end-to-end tests. End-to-end runs on hardware via Xcode UI test target with a wired-in audio file fed through `AVAudioEngine`'s mock input.
- No unit tests for view code. SwiftUI previews + manual QA only.

## Commit style
- One feature per commit. No bundled "wip" commits.
- Subject in imperative mood, ≤72 chars: `feat(asr): wire Moonshine streaming into AudioCaptureService`
- Body: bullet points on what + why. Skip the "what" if obvious from diff.
- Trailer line for Claude-authored commits: `Co-Authored-By: Claude <noreply@anthropic.com>`

## Things to never do
- Do not paraphrase the AirCaps brief in the README or repo description. Position as "a personal experiment in fully on-device meeting intelligence."
- Do not add analytics, crash reporting, or telemetry of any kind.
- Do not bundle large model files into git. Models live in `Models/` outside the repo and are downloaded on first launch from a public mirror (or shipped as Xcode asset bundle).
- Do not deactivate the audio session while nodes are running (deadlock).
- Do not ship without `NWPathMonitor` runtime privacy assertion firing on app start.
- Do not use the `AskUserQuestion` tool to ask "is this approach OK?" if the answer is in `PRD.md` or this file. Read first, ask only when ambiguous.
- Do not treat the Obsidian vault at `~/Documents/Aftertalk/` as an app feature. It is Aayush's personal documentation system + Claude session memory only. Never reference it in app code, README, or demo.

## When you're stuck
- ASR not streaming: check `examples/ios/Transcriber` in `moonshine-ai/moonshine-swift`.
- AEC dropping audio: WWDC23/10235 has the canonical AVAudioSession order.
- Foundation Models region-locked: swap to MLX Swift + Phi-4-mini behind the existing `LLMService` protocol.
- Retrieval recall poor: check full-transcript path threshold first, then hybrid BM25+dense fusion, then embedding repair state. sqlite-vec is a future scale upgrade, not the shipped vector store.
- Pyannote diarization accuracy poor: document expected accuracy in README, restrict demo to clean recordings, fix speaker count to 2 in golden test set.

## Daily 24-hr update email (to Nirbhay)
At end of each day, append a 4-bullet update to that day's brief under "Email home plate." Aayush forwards the actual email — do not draft past day 7. Tone: terse, factual, one perf number per email.

## Obsidian vault update (mandatory at session end)
The vault at `~/Documents/Aftertalk/` is Aayush's second brain for this build, NOT a feature of the app.

At session end, append to today's daily log file `~/Documents/Aftertalk/10 — Daily Logs/YYYY-MM-DD — Day N.md` with this block:

```markdown
### Session — HH:MM–HH:MM
- **What landed**: <user-visible delta>
- **Commits**: <SHA> <subject>, ...
- **Perf numbers**: <if measured>
- **Decisions**: [[ADR-XXX]] (create file under 20 — Decisions/ if new)
- **Learnings**: [[note title]] (create file under 30 — Learnings/ if new)
- **Blockers**: <none | description>
- **Questions for Aayush**: <list>
```

If a decision was made, create `~/Documents/Aftertalk/20 — Decisions/ADR-NNN <title>.md` with: context, options considered, decision, consequences. Link from daily log.

If a non-obvious learning surfaced, create `~/Documents/Aftertalk/30 — Learnings/<short-title>.md`. Link from daily log.

Update `~/Documents/Aftertalk/00 — Index.md` "Latest" section to point to today's log.

## Working directory expectations
- Repo: `/Users/theaayushstha/Desktop/Aircaps/`
- Obsidian vault: `/Users/theaayushstha/Documents/Aftertalk/`
- Models directory (gitignored, downloaded on first launch): `~/Library/Application Support/Aftertalk/Models/`
- Perf dumps: `/Users/theaayushstha/Desktop/Aircaps/perf/`
- Golden test fixtures (audio + QA pairs): `/Users/theaayushstha/Desktop/Aircaps/golden/`
