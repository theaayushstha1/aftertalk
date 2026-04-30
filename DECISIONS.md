# Architecture Decisions

A condensed record of the tradeoffs that shaped Aftertalk. Each entry follows the same shape: **decision**, **alternatives considered**, **rationale**, and **what would change my mind**. The aim is to make every non-obvious choice in this codebase auditable in under a minute.

---

## 1. Foundation Models for the LLM, not MLX + a hosted local model

**Alternatives:** MLX Swift + Phi 4 mini (3.8 B, 6 to 10 tok/s on iPhone 17 Pro), MLX Swift + Qwen 2.5 3B (4 bit), llama.cpp via XPC.

**Rationale:**
1. Foundation Models is system provided on iOS 26, so the app ships with a zero byte LLM weight footprint. MLX models are 1.5 GB to 4 GB in the bundle.
2. Snapshot streaming with `@Generable` macros gives type safe structured summaries without a JSON parsing layer.
3. ANE bound throughput on A18 sits near 30 tok/s, faster than 4 bit Phi 4 mini at the same prompt size.
4. The 4096 token cap forces explicit context budgeting, which surfaces RAG failures during development instead of in production.

**What would change my mind:** a context cap below the typical full transcript size, or a regional rollout that excluded iOS 26 in target markets.

---

## 2. Moonshine small streaming as live ASR, not WhisperKit or SpeechAnalyzer

**Alternatives:** WhisperKit (Argmax), Apple SpeechAnalyzer (iOS 26).

**Rationale:**
1. The brief explicitly preferred Moonshine. Building against the named dependency made the deliverable defensible.
2. Small stays real-time on sustained speech on iPhone. Medium is more accurate in isolation, but a 17 minute continuous reading showed it building a multi-minute backlog.
3. Native streaming architecture, designed for sub 250 ms TTFT.
4. `.ort` weights ship as data, no Core ML compile step at first launch.
5. Parakeet remains the canonical post-recording pass, so the live model optimizes for latency while stored meeting quality comes from the WAV.

**What would change my mind:** WhisperKit's ANE bound large v3 turbo would close the size gap and might overtake on accuracy. Re evaluate before a v2.

---

## 3. VAD gated streaming plus small live ASR for real-time iPhone capture

**Alternatives:** swap to small or tiny streaming variants, run medium continuously and accept lag, run medium on background priority and let it drift.

**Rationale:**
Medium streaming on iPhone can drift below real time on continuous audio. Without backpressure, audio backs up in the dispatch queue and transcripts emerge after the live mic has already stopped. Conversational meeting audio is 40 to 60 percent silence; an `EnergyVADGate` with hysteresis, hold tail, and pre roll still sheds those frames before they reach the encoder. The final submission choice is small streaming for live preview plus VAD for headroom, with Parakeet polishing the saved WAV after recording.

This is the canonical pattern. WhisperKit, Pipecat, Google Live Caption, and `whisper.cpp -vad` all wrap streaming ASR in a VAD gate.

**What would change my mind:** a future medium build that is natively real time on the target iPhones for 20 minute continuous speech without queue backlog.

---

## 4. Hybrid retrieval (dense + BM25 + RRF) instead of pure dense

**Alternatives:** dense only with NLContextual averaged token vectors, dense only with gte small Core ML, dense only with a HyDE query rewrite step.

**Rationale:**
NLContextual returns sequences of token vectors that we average to produce a chunk embedding. That captures paraphrase and topical match well, but it loses keyword precision. A question like "what did Jensen say about H100" can rank a paraphrased H200 chunk higher if the surrounding semantic context is closer. BM25 ranks by exact keyword overlap weighted by inverse document frequency, so rare words (proper nouns, model numbers, dates) carry signal.

Reciprocal Rank Fusion with k = 60 is the production standard for combining ranked lists at different score scales. A weighted score sum is hostage to whichever scale is bigger; RRF normalises by rank.

**What would change my mind:** a dedicated retrieval embedding model that ships small enough for iOS bundle and outperforms hybrid on the golden eval set.

---

## 5. Full transcript Q&A for short meetings, retrieval only for long ones

**Alternatives:** always run retrieval, always include the full transcript and rely on context truncation, dynamic context packing.

**Rationale:**
A 5 to 7 minute meeting transcript is roughly 600 to 1200 tokens. The Foundation Models prompt budget is 4096 tokens after the system prompt and generation reserve. The whole meeting fits with room to spare. When the entire transcript reaches the LLM, retrieval related failure modes (low recall, weird chunk citations, "I don't have that" disclaimers on broad questions) become impossible. Retrieval only kicks in when the transcript exceeds ~10 000 characters.

For Q&A on the demo path (the typical recording is short) this is the highest leverage fix in the entire RAG layer.

**What would change my mind:** a typical recording length above 25 minutes that wouldn't fit, or a stricter token budget on a future Foundation Models version.

---

## 6. NLContextualEmbedding instead of gte small Core ML

**Alternatives:** gte small Core ML (384 dim, ~50 MB shipped), e5 small v2 Core ML.

**Rationale:**
1. NLContextualEmbedding is a system provided asset, so the bundle ships zero embedding weight bytes.
2. The `EmbeddingService` protocol means a Core ML swap is one file.
3. For a 7 day take home, buying the bundle size back was worth a small recall hit.

The choice has tradeoffs. NLContextual averages token vectors and isn't a dedicated retrieval model. Retrieval recall on broad questions is meaningfully weaker than gte small. The hybrid retrieval decision (entry 4) is partly a mitigation for this.

**What would change my mind:** a recall@3 evaluation against gte small that shows the bundle weight is justified.

---

## 7. SwiftDataVectorStore with in process cosine, not sqlite vec

**Alternatives:** sqlite vec extension on the SwiftData backed SQLite file, VecturaKit, ObjectBox.

**Rationale:**
For the take home corpus (hundreds of chunks across a handful of meetings), an in process cosine pass over loaded Float arrays runs in under 5 ms. Loading the sqlite vec extension adds bundle weight, build complexity, and a setup step. The performance crossover where sqlite vec wins is in the tens of meetings; until then the simpler path is faster.

The vector store sits behind a `VectorStore` protocol so the swap to sqlite vec is a one file change when corpus size justifies it.

**What would change my mind:** a corpus that crosses ~50 meetings, where O(N · D) cosine starts to surface in the perf trace.

---

## 8. Hold to talk only, no automatic barge in

**Alternatives:** Silero v5 VAD with energy gate as barge in trigger, TEN VAD plus Pipecat SmartTurnV3 for full duplex.

**Rationale:**
Auto barge in requires an AEC that perfectly cancels the device's own TTS output before it reaches the mic. Apple's voice processing IO unit is good but not perfect, and Kokoro tail bleed past it consistently fired the barge in gate, which then opened a 6 second mic window that ASR happily transcribed (often as nonsense). The hold to talk pattern uses the user's button hold as the speech indicator, which is unambiguous and zero false positive.

The `BargeInController` is wired so a future Silero v5 plus AEC discipline upgrade is a swap, not a rewrite.

**What would change my mind:** Apple ships a stronger AEC API on iOS 27, or a TEN VAD plus SmartTurn pipeline that can distinguish self speech from user speech with high enough precision.

---

## 9. Embedding fallback throws and the pipeline tolerates per row failure

**Alternatives:** hard fail (early implementation), persist zero vectors as placeholders.

**Rationale:**
On a fresh airplane mode device, NLContextualEmbedding's system asset can be missing. Hard failing here meant recording, summary, transcript persistence, and chat all broke until the user connected to network and re launched. That's a worse outcome than a partial save.

The fallback design throws on every embed call, the pipeline catches and persists chunks with `embeddingDim = 0`, the retriever skips dim mismatched rows, the chat surfaces show a "Semantic Q&A unavailable" banner, and the repair tool re embeds those rows when a working service comes back online. Every layer is honest about what it has.

The earlier "return a zero vector" fallback was a poison: those rows looked legitimate at the storage layer but scored zero against any query, polluting topK ranking when few real hits existed.

**What would change my mind:** the system asset becoming a preinstalled iOS resource (no missing asset case to handle).

---

## 10. Diarization clustering threshold 0.5, with oversample then collapse

**Alternatives:** FluidAudio default 0.7, the 0.6 midpoint we tried.

**Rationale:**
The default 0.7 collapses similar timbre voices captured through one acoustic path (podcast through PC speaker into phone mic, two hosts with similar pitch). 0.6 was a midpoint we tested; field test on a 2 host podcast showed 95 percent of segments collapsed to Speaker_1.

0.5 splits real speakers reliably even on degraded audio, which produces 1 to 2 segment ghost clusters from same voice embedding drift. Those are caught by `collapseSpuriousClusters` (≤ minSegments AND <5 percent airtime, merged into nearest non ghost centroid). The post merge cleanup is the right place to handle ghosts because no single threshold satisfies both "split similar voices" and "don't drift on same voice" at once.

A subtle bug in the cleanup let two ghost clusters point at each other and survive via ID swap. Fixed by constraining merge target search to non ghost candidates, with a dedicated regression test.

**What would change my mind:** moving to FluidAudio's `OfflineDiarizerManager` plus VBx (offline file diarization with constrained clustering), which is documented as the next step.

---

## 11. `.measurement` audio session mode, not `.voiceChat` or `.videoRecording`

**Alternatives:** `.voiceChat` (Apple's voice processing IO unit), `.videoRecording`, `.default`.

**Rationale:**
Whisper class ASR was trained on audio without aggressive cleanup. Apple's voice processing IO unit (engaged by `.voiceChat`) measurably degrades Moonshine accuracy on free form transcription. `.measurement` gives the cleanest signal at the cost of leaving AEC off, which is fine because the recording surface is hold to record with no concurrent TTS.

The Q&A path uses `.playAndRecord` plus `.voiceChat` because Kokoro plays the answer through the same active session. Different scenario, different tradeoff.

**What would change my mind:** a far field condition where `.default` mode's general voice noise suppression actually improves WER on real recordings (not theory).

---

## 12. Honest TTFSW measurement, mic release to first synth dispatch

**Alternatives:** "user perceives this as the moment the voice starts" (the previous claim, which timed first LLM snapshot to first sentence handed to TTS), measure end to end including Kokoro first audio chunk.

**Rationale:**
The measurement should be honest about what it covers. Mic release to first sentence handed to the synth chain is what we can measure deterministically. Kokoro adds another ~250 to 300 ms of first audio chunk latency that we can't measure without a callback FluidAudio doesn't expose. So we report what we can prove and document the ~300 ms gap inline.

Calling our number "TTFSW" if it excludes the actual sound coming out of the speaker is the kind of claim that loses credibility. The honest framing is "first synth dispatch" with a documented offset to first audio.

**What would change my mind:** FluidAudio adds a first audio chunk callback to Kokoro, in which case we fold the measurement closed and call it true TTFSW.

---

## 13. Background diarization deferred, polish + diarize already concurrent

**Alternatives:** chunk and summarise from polish alone, run diarize as a detached task, update speaker labels in place when it completes.

**Rationale:**
Polish (Parakeet) and diarize (Pyannote) already run concurrently via `async let` in `MeetingProcessingPipeline`. On a warm device, diarize completes before polish on a typical 5 minute meeting (~10 s vs ~30 s). The parallel async let is already the optimal structure for the common case.

Fully background diarize with late updates to chunks would help only on long meetings where diarize > polish, OR on cold start. The cold start cost is amortised by `DiarizerModels.load` being prewarmed in `Task.detached(priority: .utility)` from `RootView.configurePipeline`. The remaining wins are marginal vs the refactor risk.

**What would change my mind:** a profiling capture showing diarize > polish on the typical recording length, or a UX requirement that the meeting list must show a "summary ready" state within 15 seconds of recording stop.

---

## 14. `RecordingProfile.farField` plumbed but not user toggleable

**Alternatives:** ship Classroom Mode with adaptive AGC, defer entirely.

**Rationale:**
Far field capture is microphone physics limited. SNR drops 6 dB per doubling of distance, and reverb at 0.5+ second decay times in classrooms smears phonemes regardless of gain. No on device ASR model fully recovers what the mic didn't capture cleanly. A software profile alone won't deliver lecture hall accuracy; the supported path is a wired or BT lapel mic on the speaker.

Shipping the full profile (looser VAD thresholds, 3.5× gain, longer hold tail, longer pre roll) plus a Settings toggle plus adaptive AGC is 4 to 6 hours of work that produces "better but still not great" on the worst case input. The structural plumbing is in place behind `RecordingProfile.normal` and `RecordingProfile.farField`; flipping it is one line in `RecordingViewModel`. Adaptive AGC is a separate week.

**What would change my mind:** a corpus of real classroom recordings to A/B against, plus a controlled gain ramp that demonstrably improves WER without amplifying room noise into hallucinations.

---

## 15. Tests live for the riskiest pure logic, not for view code

**Alternatives:** broader XCUITest coverage, no tests at all.

**Rationale:**
33 unit tests across 5 suites cover the modules where a regression is invisible at runtime: `EnergyVADGate.gate(samples:)`, `SentenceBoundaryDetector` (cursor invariants), `MeetingTitleSanitizer` (filler stripping), `BM25Index.tokenize`, `RRF fuseRRF` (the BM25 only hit survival case is a regression test for a P1 bug), `PyannoteDiarizationService.collapseSpuriousClusters` (ghost cycle bug).

XCUITest on SwiftUI is fragile, slow, and rarely catches real regressions for an indie codebase this size. SwiftUI previews plus on device manual QA covers the view layer at higher fidelity for less effort.

**What would change my mind:** moving to a team where nobody has the full mental model and onboarding requires automated UI regression tests.

---

## What's intentionally absent

- **No analytics.** Meetings stay on device; instrumentation that phones home would contradict the privacy claim.
- **No crash reporting SDK.** Same reason. Crashes are diagnosed via Console + sysdiagnose at submission time.
- **No Combine or RxSwift.** Swift 6 actor isolation plus AsyncStream covers the streaming surfaces (ASR deltas, FM snapshots, TTS sentences) without a third party reactive layer.
- **No CocoaPods or Carthage.** SPM only.
- **No backwards compatibility shims for iOS 25 or earlier.** Foundation Models requires iOS 26, and forking the build for older deployments isn't worth the maintenance.
