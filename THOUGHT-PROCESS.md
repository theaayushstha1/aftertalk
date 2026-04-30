# How Aftertalk Was Built

A narrative log of seven days, finals week. The aim is to make the engineering reasoning legible so the codebase reads as a sequence of intentional choices, not a pile of code that happens to compile.

For the locked architecture decisions, see [`DECISIONS.md`](DECISIONS.md). For the user facing surface, see [`README.md`](README.md).

---

## Day 0: scope and pivot

The brief landed Sunday evening. Hard requirements: record on iPhone, transcribe locally, generate a structured summary, support voice Q&A, all on device, sub 3 second time to first spoken word, demoable in airplane mode. Stretch goals: speaker diarization, streaming Q&A, cross meeting memory, neural TTS, power profiling.

The first instinct was to plan all five stretches in parallel. The better move was to lock the spine first (record then summarise then ask) and treat stretches as additive. The spine had to ship in a defensible state on day 3 so the remaining four days could pile on.

Concrete day 0 outputs:
- Picked Foundation Models for the LLM (system shipped, zero bundle weight, 4096 token cap forces honest budgeting).
- Picked Moonshine medium streaming for ASR (the brief named it; medium beats Whisper Large v3 at a fraction of the size).
- Picked NLContextualEmbedding over gte small Core ML (zero shipped weights; plan to A/B later).
- Picked SwiftDataVectorStore over sqlite vec (corpus is small; in process cosine is fast; same SwiftData store as the rest of the app).
- Picked FluidAudio Kokoro plus Pyannote (one dependency, two stretch goals).
- Decided diarization would be best effort, hold to talk would be the only auto interrupt mechanism, and the demo path would target iPhone 17 Pro Max with iPhone Air as the secondary target.

The hidden decision was to treat the take home as a senior engineering signal, not a compliance exercise. The brief asks for a working app; the goal was to ship a codebase that reads as architecturally intentional under review.

---

## Day 1: the ASR spine has to feel real

Goal: live transcript on a real iPhone, sub 250 ms TTFT, no demo mode pretending.

The naive path was AVAudioEngine plus Moonshine plus a SwiftUI label that updated on each delta. That worked in the simulator. On device it surfaced three problems immediately.

First, the audio session order matters more than any single Apple doc admits. `setCategory(.playAndRecord)` then `setMode(.measurement)` then `setPrefersEchoCancelledInput(true)` then `activate` is the only sequence that produces clean signal for ASR. Any other order silently disables AEC or routes through voice processing that degrades Moonshine accuracy.

Second, sample rate management is explicit or it fails. Mic delivers 48 kHz, ASR wants 16 kHz, Kokoro outputs 24 kHz, speakers want 48 kHz. AVAudioConverter at every boundary, never implicit graph conversion.

Third, Moonshine medium's per chunk inference latency on iPhone is just barely under real time on continuous audio. On a long recording the dispatch queue between the audio tap and the encoder fills up and transcripts emerge tens of seconds late. The solution wasn't a smaller model; it was a VAD gate that sheds silence frames before they reach Moonshine. Conversational speech is 40 to 60 percent silence, and reclaiming that fraction of the encoder budget is exactly what medium needs.

The VAD wasn't planned for day 1. Discovering its necessity on the first device test was the first signal that the build would be a sequence of "the architecture diagram on day 0 was almost right" iterations.

End of day 1: live transcript on iPhone Air, 200 ms TTFT, 12 minutes recorded continuously without lag.

---

## Day 2: structured summary and the RAG layer that wasn't yet RAG

Goal: end of recording produces a `MeetingSummary` with decisions, action items (with owners where attributable), topics, and open questions. Plus a chunked, embedded index for the next day's Q&A.

Foundation Models' `@Generable` macros made the structured output trivial. The hard part was the prompt. Models stuffed the title field with the first sentence of the transcript ("yeah and uh so basically"), invented action items from the speaker's filler, and dropped owners when names appeared mid sentence. The fix wasn't more clever prompting; it was a `MeetingTitleSanitizer` that ran at persistence time and rejected bad titles before they reached the meetings list. Sanitizer ladder: accept the FM title if it passes the noun phrase plus word count plus filler check, else mine a salient noun via NLTagger, else fall back to a dated string.

Embedding wise, NLContextualEmbedding gave 512 dim vectors of the meaning of a chunk. That's good enough for prototype level retrieval, not great for production. The decision to ship NLContextual was a tradeoff: zero bundle weight versus stronger but heavier retrieval. The bet was that hybrid retrieval (added later) would mitigate.

Chunking happens in 4 sentence windows with 1 sentence overlap. Transcript text gets split by `NLTokenizer` at sentence boundaries; Parakeet polish (added later) gives word level timings so chunks can carry start and end seconds.

End of day 2: a 5 minute test meeting produces a clean structured summary, embeds 12 chunks, and answers "what was the meeting about" by retrieving the right span.

---

## Day 3: the Q&A loop closes

Goal: hold to talk question becomes voice answer in under 3 seconds. Ground truth: it has to actually work, not just demo.

The first iteration concatenated four pieces: question ASR, retrieval, LLM call, AVSpeechSynthesizer. Each piece worked individually. End to end, time to first spoken word was about 5 seconds because every step ran serially. The fix was streaming everywhere. Foundation Models gives `streamResponse` with snapshot updates roughly every 30 ms. A `SentenceBoundaryDetector` consumes those snapshots and emits sentences as they complete. A `TTSWorker` actor schedules each sentence for synthesis the moment it's ready, with the next sentence pre warming behind it. By the time sentence 1 finishes playing, sentence 2 is already loaded.

The grounding gate landed on day 3 too. The pattern is from CS Navigator v5: if retrieval returns nothing meaningful, refuse honestly instead of letting the LLM hallucinate. The threshold was 0.40 for gte small intuition. Later it dropped to 0.22 for NLContextual's tighter cosine distribution, then 0.10 after another empirical pass. The hard gate became a soft gate on day 7: only refuse when there's truly no chunks AND no summary, otherwise let the LLM see whatever structured context exists and decide.

Per meeting and global chat both shipped on day 3. The QAOrchestrator is one struct that owns the retrieve plus generate plus speak chain; the retriever is a `HierarchicalRetriever` that does Layer 1 (summary search) plus Layer 2 (chunk search inside top meetings). ContextPacker handles token budget assembly with explicit truncation policy.

End of day 3: full speech in speech out loop closes in 1.4 seconds on iPhone Air. Voice in, voice out, grounded. The spine is shippable.

---

## Day 4: neural TTS and diarization

Goal: replace AVSpeechSynthesizer with Kokoro 82M (the FluidAudio ANE port), ship Pyannote 3.1 plus WeSpeaker v2 diarization, and not break anything.

Kokoro was harder than expected. The G2P, voice pack, and vocab loaders ignore the directory argument we pass and hardcode lookups to the FluidAudio cache. The fix was a staging step: build a writable tree at `<Caches>/fluidaudio/Models/kokoro/` populated with copies (not symlinks; FluidAudio's `fileExists` check returns false for cross sandbox symlinks on iOS). Documented inline because a fresh contributor would otherwise spend an hour on the same diagnosis.

Diarization clustering is the longest running tradeoff in the codebase. The default threshold (0.7) collapses similar timbre voices captured through one acoustic path. Lowering to 0.5 splits real speakers but spawns 1 to 2 segment ghost clusters. The "oversample then collapse" pattern (permissive threshold, post merge tiny clusters by centroid distance) is the standard fix in the literature. A subtle bug in the cleanup let two ghost clusters point at each other and survive via ID swap; that became a regression test.

End of day 4: voice answers play through Kokoro at 24 kHz, diarized chunks attribute action items to the right speaker, lazy warm pattern keeps iPhone Air under the iOS 26 jetsam ceiling.

---

## Day 5: Quiet Studio refactor and cross meeting memory

Goal: editorial UI pass against the Quiet Studio handoff. Onboarding, Record, Meetings, Detail (Summary plus Transcript plus Actions tabs), Ask, Global Ask, Settings (live privacy audit). Plus cross meeting memory (Layer 1 summary search routes Q&A across meetings).

The UI work was bigger than expected. The Quiet Studio palette has tight contrast requirements (ink near black on cream surfaces for AA), and SwiftUI's button tint inheritance was washing out NavigationLink labels and AuditRow text. Fix was hardcoded ink on the labels, not relying on inherited foreground. The tab bar plus floating record FAB pattern let users navigate during a live recording without losing the audio engine, which became table stakes for a credible demo.

Cross meeting Q&A used the global Layer 1 summary search to pick top K meetings, then chunk search inside that scope. The summary embedding shape (title plus topics plus decisions plus actions) was tuned so a question like "what has Sara committed to overall" routes to meetings where Sara appeared in action items, not just any meeting that mentioned Sara in passing.

End of day 5: full Quiet Studio UI, cross meeting Q&A grounded by Layer 1 routing, Settings panel with live privacy audit counts.

---

## Day 6: polish and reliability

Goal: ergonomics, edge cases, the things a reviewer breaks on first try.

Recording flow: minimize while recording (chevron plus floating "RECORDING · MM:SS" pill across tabs, audio engine plus Moonshine streamer keep running). Persistent "Summary ready" banner replaced with an auto dismissing top of screen pipeline toast that hard resets when a new recording starts. Hold to ask CTA lifted clear of the tab bar's record FAB.

Phone call plus Siri plus route change interruption handling: AVAudioSession's `interruptionNotification` fires `.began` then `.ended` (with `.shouldResume`). The capture engine pauses in place; on `.shouldResume` it resumes. If the OS says don't resume, the recording stays in `.interrupted` state with a banner so the user can stop manually.

Time aware Parakeet detokenizer (was emitting "st age" / "Vanc ouv er"; now resolves subword splits via 20 ms audio gap heuristic). Safety classifier refusal retry via map reduce halving. View side meetings dedupe for the rare re fired session edge case.

Far field ASR conditioning: 6 dB linear gain plus tanh soft clip on the streaming feed so >1 m speakers land in Moonshine's encoder operating range. The WAV destination kept raw audio for honest playback; later, on day 7, that became a bug because Parakeet polish then read raw audio while Moonshine saw boosted audio and got better results on quiet speakers.

End of day 6: polish flow demoable, reliability fixes for the post recording path, perf chart pipeline scaffolded.

---

## Day 7: the late week review pass

Day 7 was supposed to be demo video plus README plus submit. It became a major architectural pass driven by a sequence of code reviews that surfaced real failure modes under harder testing.

The reviews were sharp. They caught:

1. The grounding gate fired too early on broad questions, refusing meetings whose summary already contained the answer.
2. NLContextual averaged token vectors aren't a purpose built retriever; dense only retrieval was fragile on questions where keyword precision mattered.
3. Global Ask only saw summaries for meetings that retrieval already hit; if retrieval missed, the LLM had no fallback.
4. Q&A ASR shouldn't double count voice activity (the user's button hold is the signal); the VAD gate was clipping quiet questions.
5. Diarization threshold 0.6 was an over correction from 0.5; field tests showed 95 percent collapse to Speaker_1 on PC speaker audio.
6. The embedding fallback persisted zero vectors that poisoned future retrieval.
7. The TTFSW measurement was claiming "first spoken word" while measuring "first sentence handed to synth" (off by ~300 ms).

Each of these was a genuine bug, not a theoretical concern. The day 7 fixes are the heaviest commits in the repo.

The biggest move was the **full transcript Q&A path**. A 5 to 7 minute meeting transcript fits in Foundation Models' 4096 token prompt with room to spare. When the transcript is short enough, retrieval is pure ceremony and a failure surface; skip it entirely and put the whole thing in the prompt. For ≤ 7 minute meetings this turns RAG related failure modes into a non issue. This is the demo killer move. Retrieval related disclaimers vanish for the typical recording.

The second big move was **hybrid retrieval** (BM25 + dense + Reciprocal Rank Fusion). BM25 catches keyword precision (proper nouns, model numbers, dates) where dense paraphrase recall fails. RRF with k = 60 fuses the two ranked lists. Production standard pattern from Cormack et al. 2009. A subtle bug in the first version dropped BM25 only hits at the fusion step; fixed by hydrating BM25's output to the same `ChunkHit` shape the dense store returns.

The **soft grounding gate** replaced the hard threshold check. Refuse only when there's truly no chunks AND no summary on the device. If a structured summary exists, always call the LLM and let it decide. The hard gate was a holdover from an earlier embedding model with different cosine distribution; with NLContextual it was firing on questions whose answer was in the summary.

The **embedding fallback** got rebuilt. Earlier it persisted 8 dim zero vectors. That looked legitimate at the storage layer but scored zero against any query, polluting topK ranking when few real hits existed. The fix is throw on every embed call, persist with `embeddingDim = 0`, retriever skips dim mismatched rows, repair tool re embeds when a working service comes back. Every layer is honest about what it has.

**Q&A VAD bypass** for hold to talk: the user holding the button IS the voice activity signal we'd otherwise infer from RMS. Gating again was double counting and clipped quiet questions.

**Diarization 0.6 reverted to 0.5**: 0.6 collapsed real speakers on degraded acoustic input. 0.5 splits speakers reliably; the post merge cleanup (now with the cycle bug fix and unit test) catches the ghost clusters that come with permissive threshold.

**Honest TTFSW**: measure mic release to first sentence handed to synth. Document the ~300 ms Kokoro first audio gap inline. Don't claim "first spoken word" for a number that excludes the actual sound coming out of the speaker.

End of day 7: 33 unit tests passing, build warning clean, README rebuilt with real device demo gif, docs aligned with code, GitHub topics set, repo public.

---

## What I'd build with another two weeks

These are documented in the README's "Known limits" section and as decision deferrals in [`DECISIONS.md`](DECISIONS.md). In priority order:

1. **Classroom Mode UI toggle plus adaptive AGC.** Profile plumbing exists; needs a Settings affordance and a real noise floor estimator so amplified room noise doesn't spawn fake words.
2. **FluidAudio OfflineDiarizerManager plus VBx.** The bundle has the offline assets; the API is different and needs A/B against the current Pyannote streaming path.
3. **Background diarization.** Polish and diarize already run concurrently; further decoupling lets summary persist and Q&A start before diarization completes, with speaker labels populating in place when ready.
4. **Repair tool UI.** The data layer methods exist (`indexHealth`, `repairSemanticIndex`); a Settings affordance to surface them is one screen of SwiftUI.
5. **Recall@3 evaluation harness.** Golden QA set under `golden/` plus a Python harness that scores recall at 3 across NLContextual vs gte small. Would let us pick the right embedding for the corpus instead of guessing.
6. **Real 30 minute plus 10 minute device perf capture.** The CSV pipeline ships; the run hasn't happened yet because the demo flow burned the testing budget.

---

## Patterns I reused from prior work

These aren't code reuse (different language, different runtime). They're architectural patterns that worked in production and ported cleanly:

| Pattern | Where it shipped before | Where it lands here |
|---|---|---|
| Grounding gate (refuse instead of hallucinate when retrieval has nothing) | CS Navigator v5, 1450+ student chats audited | Q&A disclaimer path; soft gated on day 7 |
| 3 layer follow up resolver (regex override; deterministic entity focus; LLM fallback) | CS Navigator v5 production | Future Q&A thread context resolution; not shipped yet |
| Pre compute "context cards" at indexing time | CS Navigator Course Context Engine | Speaker cards built once at summary time, retrieved before chunk level retrieval falls through |
| Multi account skill pattern (single dependency surface, multiple personas) | Gmail / GCal skills, 120+ installs | Each meeting is its own "account" with chat thread plus speaker cards plus summary cards |
| Push to talk plus ASR plus LLM plus TTS loop | NAO6 robot research at Michigan State | Aftertalk's record button plus Q&A trigger; ML driven speaker tagging instead of face recognition |

The through line: the grounding gate that prevents hallucination at 1450+ student chats is the same gate that prevents Aftertalk from making up meeting decisions. That's the architectural through line worth telling.

---

## Honest takeaways

- **Building against the brief is not the same as building the product the brief implies.** The brief asked for an app; the goal was to ship a codebase that reads as architecturally intentional. Most of the day 7 work was upgrading "works in the demo" to "passes a code review by someone who's seen this kind of system before."
- **Real device testing surfaces real problems.** Every major architectural shift in this repo came from a device test that contradicted what worked in the simulator. The simulator passes 33 tests in 0.08 seconds; the device exposed the dispatch queue backpressure, the diarization threshold cliff, and the embedding poison case.
- **The biggest fix is usually the simplest.** Full transcript Q&A is 50 lines and converts the entire RAG layer's failure surface into a non issue for the demo case. Hybrid retrieval is more code but doesn't move the needle on the typical recording. Pick the simple fix that eliminates a class of failures over the production correct fix that mitigates them.
- **Honest beats polished.** The README, the commit messages, and `DECISIONS.md` all err toward saying what's true even when it's less flattering. Reviewers can tell the difference, and the cost of bullshit caught later is much higher than the cost of admitting a tradeoff up front.
