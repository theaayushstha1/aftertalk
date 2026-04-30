---
title: "Aftertalk — The Complete Reference"
subtitle: "On-device meeting intelligence for iOS 26+. From zero to one hundred."
author: "Aayush Shrestha"
date: "April 30, 2026"
---

# Foreword

This document is a single source of truth for the Aftertalk project. It walks the entire system from a thirty thousand foot product pitch all the way down to the specific reasons certain constants are set the way they are. It is written to be read aloud — every section is a few self-contained paragraphs that explain not only what was built, but why each choice was made and which alternatives were considered first. If you load this PDF into NotebookLM, the resulting audio summary should give you a faithful tour of the project from start to finish without any other context.

The project itself is a seven day take home submission for AirCaps, a Y Combinator F25 company, that gates an in person paid work trial. The brief asked for a fully on device iOS application that can record a meeting, transcribe it, summarize it, and let a user ask spoken questions of the recording — all without sending any audio, transcript, or query off the phone. The final submission is a real iPhone application, an open source GitHub repository, and a screen recorded demo that shows the complete loop with airplane mode visible the entire time. This document is the engineering narrative behind that submission.

# Part One — What Aftertalk Is

## The product in one paragraph

Aftertalk is an iOS 26+ application that turns a spoken meeting into a structured set of notes and a voice driven question and answer surface. You hit record, you have a meeting, you hit stop. The phone transcribes the audio locally with a streaming speech recognition model, then re-runs a higher quality model on the saved waveform for a polish pass with word level timings. A diarization model groups segments by speaker. A large language model that ships with iOS 26 reads the polished transcript and produces a structured summary — decisions, action items with owners, topics, and open questions. The transcript and summary are indexed for semantic search. You can then hold a button and ask any question in natural language, either scoped to one meeting or across every meeting you have ever recorded. The phone retrieves the relevant excerpts, generates an answer, and reads it back to you in a synthesized voice. None of this requires the network. The phone can be in airplane mode the entire time.

## The pitch

The privacy story is not a marketing claim. It is the entire reason the application exists. Existing meeting note tools either send raw audio to a vendor's cloud, or skip transcription entirely and rely on the user to capture details by hand. Aftertalk runs the whole pipeline on the phone — speech recognition, summarization, retrieval over many meetings, voice answer with neural text to speech — and exposes a runtime assertion that fails loudly if any network interface is up while a meeting is recording. Users who care about privacy do not have to take our word for it. The repository contains a static grep that proves no networking APIs are imported in production code paths, the runtime monitor watches for violations, and the demo video shows airplane mode in the iPhone control center for the duration of the recording.

## The user

The intended user is a founder, product manager, or researcher who attends five to fifteen meetings a week, takes notes inconsistently, and is unwilling to send sensitive conversations to a third party AI vendor. They are willing to put the phone in airplane mode for the duration of a meeting in exchange for a privacy guarantee that is verifiable rather than just claimed. They are technical enough to appreciate that on device transcription has a slightly higher word error rate than a cloud Whisper deployment, and care more about provenance than perfection.

# Part Two — Why This Project Exists

## The take home brief

AirCaps shipped a brief that asked for the full meeting application — record, transcribe, summarize, voice ask. It explicitly preferred Moonshine for the streaming speech recognition layer because Moonshine ships native iOS Swift bindings and was designed for low latency on edge hardware. It allowed any local language model and asked the candidate to justify the choice. It listed several optional stretch goals — speaker diarization, streaming text to speech, cross meeting memory, neural text to speech, power profiling — and made clear that hitting them would distinguish a product from a demo. The brief gave a deadline of seven days and a target time to first spoken word of under three seconds on iPhone 14 or later.

The submission deliverable is the public GitHub repository, a screen recorded video, and a one page benchmark report. There is no expectation that the application will pass App Store review, do background processing, or run on devices older than iPhone 14. There is also no expectation that the application will work without iOS 26, since Apple's Foundation Models framework — the system provided language model — was introduced at WWDC 25 and ships with that operating system version.

## Why over deliver

A take home that hits only the required functional requirements demonstrates that the candidate can read a brief and ship working code. A take home that hits all the stretch goals and goes a few steps beyond demonstrates that the candidate has product instinct. Aftertalk hits every required requirement, every stretch goal, and a handful of quality of life additions that were not asked for — global cross meeting chat, citation tap to source span, transcript copy with iOS file protection, a runtime privacy monitor that fails loudly, an in app repair tool that re-embeds chunks when the system embedding asset is missing on first launch, and a dock that lets the user type questions in addition to speaking them. The bet is that an interviewer at AirCaps would rather see a product than a demo, and that the marginal cost of shipping the polish was worth the marginal credibility lift.

# Part Three — System Architecture at the Whiteboard Level

## The pipeline in plain English

Audio enters the phone through the built in microphone using AVAudioEngine. The signal is forty eight kilohertz and is converted down to sixteen kilohertz before reaching the speech recognition stage, because Moonshine and most other models on this layer expect a sixteen kilohertz signal. An energy based voice activity gate sits between the converter and the speech recognizer and sheds frames that are below speech threshold, which is roughly forty to sixty percent of conversational audio. The voice activity gate exists not to improve accuracy but to keep the streaming model from accumulating a backlog when audio is dense and the encoder is slow. The shipped live recognizer is the small streaming Moonshine variant — a seventeen minute continuous reading test on iPhone showed the medium streaming model building up several minutes of latency, so we dropped to small for the live preview and let Parakeet handle the higher quality polish on the saved waveform after recording stops.

The recognized text is emitted in deltas as the user speaks. The deltas append to an ongoing buffer that powers the live preview on screen. A waveform updates in real time. When the user hits stop, the live recognizer is shut down and a higher quality batch model — Parakeet from FluidAudio — runs on the saved waveform and produces a polished transcript with word level timings. Concurrently with the polish pass, a diarization model runs on the same waveform and produces speaker segments. The polished transcript and the speaker segments are reconciled — we know which words were said by which speaker — and the result becomes the canonical transcript that the user sees in the meeting detail view.

The canonical transcript is then chunked into roughly four sentence windows with a one sentence overlap, and each chunk is embedded using Apple's NLContextualEmbedding system asset. The embedded chunks land in SwiftData. A summary embedding is also generated for the meeting as a whole. Foundation Models then reads the polished transcript and emits a structured summary using the Generable macro — decisions, action items, topics, open questions, with owners attached where the language is clear about it. The summary is stored alongside the meeting and surfaced as the first tab the user sees when they open a meeting.

When the user wants to ask a question, they hit the dock, either by typing or by holding the microphone button. If they hold the button, a separate audio session is configured for measurement quality input — Moonshine sees the cleanest signal — and the question is recognized in real time. When the user releases the button, a brief tail of silence is appended to the audio buffer to flush the recognizer, and the final question is captured. If they type, the same code path runs with the typed string standing in for the recognized one.

The question is then routed through the orchestrator. Short meetings under ten thousand characters skip retrieval entirely and put the whole transcript in the language model prompt, because the four kilo token Foundation Models budget can hold a five to seven minute meeting transcript with room for the system prompt, the question, and the answer. Longer meetings go through hybrid retrieval — a dense semantic search using NLContextualEmbedding and a BM25 keyword search are run in parallel and their ranked lists are combined using Reciprocal Rank Fusion. The top three to eight chunks become the retrieved context. A grounding gate sits in front of the language model: if no chunks score above the similarity threshold and there is no summary to fall back on, the orchestrator returns a "I do not have that in the meeting transcripts" disclaimer rather than asking the model to answer ungrounded.

The language model's response streams in. A sentence boundary detector reads the stream and emits complete sentences as soon as terminal punctuation is found. Each sentence is batched into roughly a hundred and thirty character clips, the clips are handed to Kokoro, and Kokoro synthesizes audio at twenty four kilohertz on the Neural Engine. The audio is converted up to forty eight kilohertz and scheduled on an AVAudioPlayerNode that is configured for sequential playback. The player drains while the next sentence is still synthesizing, so the user hears a continuous answer rather than a stuttering one.

The playback path is intentionally conservative. Kokoro audio uses a speech playback session and the microphone is not kept open for automatic interruption in the shipped build. The user asks the next question by holding the button again or by typing in the dock. Auto interrupt was deferred because the energy based gate misfired on the tail of Kokoro audio bleeding through the device route, which created false follow up turns.

## The audio session story

The single most fragile part of the application is the audio session. iOS exposes a global AVAudioSession object that every audio aware framework on the device shares. Misconfiguring it produces silent failures — the microphone goes hot but the speaker stays silent, or playback route changes fail with error code minus fifty. The application now uses separate, simpler configurations. Meeting recording and spoken questions use measurement quality input so Moonshine and Parakeet see minimally processed audio. Kokoro playback uses a conservative playback plus spoken audio route and falls back to plain playback if a route rejects the richer spoken audio options. The shipped build does not keep the microphone armed during TTS; if automatic barge in is reintroduced, it should be guarded behind a dedicated voiceChat configuration and a real VAD rather than the current energy gate.

# Part Four — Why Each Model

## Live speech recognition: Moonshine small streaming

Moonshine was the brief's preferred choice and shipping against the named dependency made the deliverable defensible. Within the Moonshine family there are four model sizes — tiny, small, medium, and large — and we tested each one on a real device. Medium stayed real time only for short bursts; on a sustained seventeen minute test reading it built a multi minute backlog because the encoder could not keep up with the input rate. Small stayed real time for the full duration. Tiny was real time but had visibly worse accuracy. The trade off settled at small streaming for the live preview, with a higher quality Parakeet pass running after recording stops. The application optimizes the live model for latency and the stored transcript for quality, which is the right division of responsibilities.

## Post recording polish: Parakeet TDT zero point six billion v two

Parakeet is a dedicated batch automatic speech recognition model from FluidAudio with word level timings and lower word error rate than streaming Moonshine. It runs once on the saved waveform after recording stops and is the canonical transcript that powers the meeting detail view. The trade off is that Parakeet is not streaming — there is a roughly fifteen to thirty second gap between hitting stop and seeing the polished transcript on a five minute recording — but the user experience is forgiving because the live transcript is already on screen and the polish pass updates it in place when ready.

## Language model: Apple Foundation Models

This is the highest leverage model choice in the entire application. Foundation Models is system provided on iOS 26, which means the application bundle ships with zero bytes of language model weight. The MLX Swift alternative would have added one and a half to four gigabytes to the bundle. Foundation Models also provides snapshot streaming and the Generable macro, which lets us declare a Swift struct for the meeting summary and have the model fill it in directly without a JSON parsing layer. The throughput on A18 hardware sits near thirty tokens per second, which is faster than four bit Phi 4 mini at the same prompt size. The four kilo token context cap forces explicit budgeting, which surfaces retrieval failures during development rather than in front of the user. The only thing that would change the choice is a regional rollout that excluded iOS 26 in target markets, or a context cap below the typical full transcript size.

## Embeddings: NLContextualEmbedding

The embedding model is an Apple system asset, which means zero bytes shipped in the bundle and always available on iOS 26+ devices. The trade off is that NLContextualEmbedding is not a dedicated retrieval model — it averages token vectors to produce a chunk embedding, and the resulting recall on broad questions is meaningfully weaker than a model like gte small that was trained specifically for retrieval. The hybrid retrieval design — combining the dense search with a keyword based BM25 search using Reciprocal Rank Fusion — is partly a mitigation for this weakness. If recall on the golden evaluation set ever surfaced as a real problem, the embedding service is behind a protocol and a swap to gte small Core ML is a one file change.

## Vector store: SwiftDataVectorStore

Vector search uses an in process cosine pass over Float arrays loaded from SwiftData rows. For the take home corpus of hundreds of chunks across a handful of meetings, the cosine pass runs in under five milliseconds and there is no benefit to integrating sqlite vec, which would add bundle weight, build complexity, and an extension loading step. The vector store sits behind a protocol so the swap to sqlite vec is a one file change when the corpus crosses fifty meetings or so.

## Diarization: FluidAudio Pyannote three point one with WeSpeaker v two

FluidAudio ships an iOS port of Pyannote with WeSpeaker embeddings that runs on the Neural Engine at sixty times real time. The clustering threshold is set to zero point five, which is more aggressive than the FluidAudio default of zero point seven, because the default collapses similar timbre voices captured through a single acoustic path — a podcast playing through a PC speaker into the phone microphone, two hosts with similar pitch — into one speaker. The aggressive threshold occasionally produces ghost clusters of one or two segments from same voice embedding drift, and a post merge cleanup pass folds those ghosts into the nearest non ghost speaker centroid. A subtle bug in the cleanup let two ghost clusters point at each other and survive via ID swap; that is fixed and there is a regression test for it.

## Text to speech: FluidAudio Kokoro 82M

Kokoro is an eighty two million parameter neural text to speech model that runs on the Apple Neural Engine at fifty times real time. It produces about four hundred milliseconds of audio for the first sentence of an answer and the application is configured to use only the five second graph variant — the fifteen second variant adds three hundred and ten megabytes of resident memory and was tipping the iPhone Air over the iOS jetsam ceiling during the first answer. Long sentences are batched into clips of up to a hundred and fifty characters, which is well below the five second graph budget at typical English phoneme density, so any single Kokoro inference fits in one graph pass and we never trigger the lazy load of the larger graph.

# Part Five — The Retrieval Design

## Why hybrid

Pure dense retrieval with NLContextualEmbedding ranks paraphrased context highly, which is good when the user asks something like "what did the speaker say about model performance" and the relevant chunk uses the words "throughput" and "scaling" instead. But pure dense ranks a chunk with the wrong proper noun very close to a chunk with the right one, because the surrounding semantic context dominates the average. A question like "what did Jensen say about the H100" can rank an H200 chunk higher if the rest of the words match. BM25, the keyword based ranker, weights rare terms by inverse document frequency. Proper nouns, model numbers, and specific dates carry strong BM25 signal. Combining the two ranked lists produces a result set that is robust to both paraphrase and keyword precision questions.

## Reciprocal Rank Fusion

The two ranked lists run in parallel and their results are combined using Reciprocal Rank Fusion with a constant of sixty, which is the production standard pulled from the Cormack et al paper. RRF normalizes by rank rather than score, so the two scoring scales — cosine similarity from zero to one and BM25 raw scores in the tens — do not have to be calibrated against each other. The fusion produces a single ranked list of chunks that is uniformly more accurate than either ranker alone on a small golden evaluation set we hand built from a synthetic two speaker meeting.

## The full transcript shortcut

Most meetings recorded during a take home review or a real demo are five to seven minutes long. A five minute meeting transcript is roughly six hundred to twelve hundred tokens. Foundation Models has a four kilo token cap. Subtracting a system prompt of about two hundred fifty tokens, a question of about fifty tokens, and a generation reserve of about twelve hundred tokens leaves about twenty four hundred tokens of context budget. The full transcript fits easily, with room to spare. When the entire transcript reaches the language model directly, every retrieval related failure mode disappears — there is no recall problem, there are no missing chunks, there are no awkward "I do not have that" disclaimers on broad questions. The application skips retrieval entirely for any meeting under ten thousand characters and only invokes the hybrid pipeline above that threshold. For the demo path, this is the highest leverage decision in the entire retrieval layer.

## Grounding gate

When retrieval is required and the top chunk score falls below the similarity threshold and the retrieval pulls back zero usable chunks, the orchestrator does not call the language model at all. It returns a fixed disclaimer — "I do not have that in the meeting transcripts" — instead of asking Foundation Models to answer ungrounded. This pattern was carried over from CS Navigator v5, an earlier production project, where it stopped a five percent hallucination rate cold across fourteen hundred and fifty student chats. The same pattern works here. If you ask Aftertalk something that has nothing to do with the meeting, it tells you so rather than making up an answer that sounds plausible.

# Part Six — The Text to Speech Pipeline

## Streaming over batch

The naive pattern is to wait for the language model to finish generating the entire answer, hand the full text to Kokoro in one synthesis call, play the audio. That works but the user waits two to four seconds for the first sound. The streaming pattern reads the language model snapshot stream as it arrives, runs a sentence boundary detector that emits a complete sentence the moment terminal punctuation lands, hands each sentence to Kokoro, and plays each clip the moment it is synthesized. The user hears the first word of the answer in around one and a half seconds, well under the brief's three second target.

## Sentence batching

Each Kokoro inference has a small leading silence pad and a small trailing silence pad. When sentences are short and back to back, the pads stack and the user perceives a breath between every sentence. The sentence boundary detector and the orchestrator together batch short sentences into clips of about a hundred and thirty characters, which covers two short sentences in one inference and roughly halves the seam count. The maximum is set to a hundred and fifty characters to stay safely under Kokoro's five second graph budget at typical English phoneme density.

## Polish

After Kokoro returns, a polish pass trims the leading and trailing silence pads down to twenty two milliseconds and forty five milliseconds respectively, applies an eight millisecond linear fade at each edge to mask any amplitude click at the trim boundary, and prevents output clipping by scaling the signal if the peak exceeds zero point nine eight. The polish pass produces audio that schedules cleanly back to back without audible seams.

## Player and hardware route

The player node is connected to the main mixer, which is connected to the speaker output. An observer on AVAudioEngineConfigurationChange watches for hardware route changes — AirPods connecting or disconnecting, CarPlay flipping, the audio session being re-initialized after an interruption. When the route changes, the cached output format and converter go stale and the next Kokoro buffer would crackle or drop frames. The handler flips a flag that forces the next buffer enqueue to rebuild the engine graph against the new hardware sample rate.

# Part Seven — The Privacy Story

## The runtime monitor

PrivacyMonitor is an Observable class that wraps NWPathMonitor. It exposes a state — unknown, offline, online but idle, or violation — and a Boolean called isCapturingMeeting. RecordingViewModel sets the boolean to true the moment a recording starts and sets it to false on stop or rollback. If any network interface is up while isCapturingMeeting is true, the state flips to violation and a fault level log fires with the offending interface names. The privacy badge in the application's chrome reads the state directly and turns red when there is a violation. This is not a marketing claim; it is a runtime assertion that fires loudly if the application's behavior ever drifts away from the privacy promise.

## Static auditability

A grep for URLSession, URLRequest, NSAllowsArbitraryLoads, and NSAppTransportSecurity across the entire Swift source tree returns zero matches. Any contributor adding a network call would have to also remove this assertion, and the diff would be obvious in code review. The README points readers at the specific commits that introduced each privacy invariant.

## Logging discipline

Every app-owned Logger call uses the os Logger framework with the privacy parameter explicitly set. Counts, durations, error types, sample rates, and file basenames are public. Anything that could carry user content — the question text, the answer text, the transcript text, speaker names, even short previews — is either omitted entirely or reduced to length-only fields. A recent code review pass tightened the previously interpolated previews ("term=…", "q=…", forty character chains) to fields like "termLen=…", "qLen=…", and "chars=…". One honest caveat: third-party debug logging from FluidAudio can still print synthesized TTS text in Xcode or device logs during debug runs. That is local-only and not a network leak, but app-owned logs do not claim control over third-party package debug output.

## Pasteboard hardening

When the user copies the transcript, the application uses UIPasteboard's setItems with localOnly set to true and an expiration date ten minutes in the future. The transcript does not propagate to other devices via Universal Clipboard, and it expires from the local pasteboard after a brief window so a second app cannot read it indefinitely.

## File protection

Recording WAV files and performance CSVs are stamped with the FileProtectionType completeUntilFirstUserAuthentication attribute. The file is encrypted at rest and is decrypted only after the first unlock following a reboot. Background flushes still work, which is the right balance for a recorder; the stricter complete protection level would break flushes that fire while the device is locked.

# Part Eight — Hard Problems and How We Solved Them

## Real time on a streaming model

Medium streaming Moonshine on iPhone drifts below real time on continuous speech because the encoder cannot keep up with the input rate. Without intervention, audio backs up in the dispatch queue and the transcript emerges after the live microphone has already stopped. The solution was to drop the live model down to small streaming, which stays real time on sustained speech, and add an energy based voice activity gate with hysteresis, hold tail, and pre roll between the audio converter and the recognizer. The gate sheds frames that are below speech threshold, which is forty to sixty percent of conversational audio. The combination of small streaming and the voice activity gate was the right answer for the live preview, while Parakeet handles the higher quality polish pass on the saved waveform.

## The Foundation Models four kilo token cap

The first version of the Q&A system used pure retrieval and routinely produced disclaimers on broad questions because the chunk recall was weak on short meetings. The fix was the full transcript shortcut described above, plus the hybrid retrieval design for longer meetings. Both layers landed before the demo and together they eliminate the retrieval failure mode the take home reviewer would have seen.

## Diarization on degraded audio

The default Pyannote clustering threshold of zero point seven collapses similar timbre voices captured through a single acoustic path. The threshold was lowered to zero point five, which split real speakers reliably but produced one or two segment ghost clusters from same voice embedding drift. The post merge cleanup pass folds those ghosts into the nearest non ghost centroid. A subtle bug let two ghost clusters point at each other and survive via ID swap; the fix constrains the merge target search to non ghost candidates and the regression test fires every time the suite runs.

## Embedding asset missing on cold start

NLContextualEmbedding's English asset is downloaded by iOS the first time it is requested. On a fresh airplane mode device, the asset is missing and a hard failure here would break the entire pipeline — recording, summary, transcript persistence, chat — until the device connected to network. The fix is a fallback that throws on every embed call rather than returning a zero vector. The pipeline catches the throw and persists chunks with embeddingDim equal to zero. The retriever skips dim mismatched rows. The chat surfaces show a "Semantic Q&A unavailable" banner. A repair tool re-embeds those rows when a working service comes back online. Every layer is honest about what it has.

## TTSWorker mid buffer cuts

On a real device under memory pressure from Foundation Models, AVAudioPlayerNode would occasionally drop buffers mid playback. The fix was to keep our own retain map of scheduled buffers keyed by buffer ID, with the buffer cleared from the map only when its completion handler fires. AVFoundation normally retains scheduled buffers itself, but the explicit retention closes a real device failure mode where buffers were getting collected before playback completed.

## Audio session error code minus fifty

When the orchestrator switches the audio session from measurement mode for question recognition to voice chat mode for answer playback, the session configure call occasionally fails with NSOSStatusErrorDomain code minus fifty. The error fires because the session is held by another component in a state that does not allow the requested change. The orchestrator catches the error, logs a continuing with current mode warning, and proceeds. The user hears the answer through the existing session. This is the only audio session error path that occurs in real device testing, and the fall through is correct.

## Memory pressure on iPhone Air

The iPhone Air has less working memory than the iPhone 17 Pro Max and was tipping over the iOS jetsam ceiling on the first Q&A turn after a recording. The first fix was to defer Kokoro warm out of app launch and into the chat tab task, so the three hundred megabyte text to speech graph loads only when the user opens chat rather than alongside the three gigabyte language model graph at app start. The second fix was pinning Kokoro to the five second graph variant and skipping the fifteen second variant entirely, which saves another three hundred and ten megabytes of resident memory. The third fix was hard cleanup on meeting exit — Kokoro tears down and the audio session deactivates when MeetingDetailView disappears.

# Part Nine — The Decisions Log

What follows is the condensed decisions log. Each decision lists the alternatives considered, the rationale, and what would change the choice. The full log lives in DECISIONS.md in the repository.

The first decision was Foundation Models for the language model rather than MLX with a hosted local model. The alternatives were MLX Swift with Phi 4 mini or Qwen 2.5 three billion four bit, or llama.cpp via XPC. The rationale was that Foundation Models is system provided on iOS 26 and the application bundle ships with zero bytes of language model weight, that the snapshot streaming with Generable macros gives type safe structured summaries without a JSON parsing layer, that the throughput on A18 hardware sits near thirty tokens per second which is faster than four bit Phi 4 mini at the same prompt size, and that the four kilo token cap forces explicit context budgeting which surfaces retrieval failures during development rather than in production.

The second decision was Moonshine small streaming for live speech recognition, not WhisperKit or Apple SpeechAnalyzer. The brief explicitly preferred Moonshine and shipping against the named dependency made the deliverable defensible. Within the Moonshine family, small stays real time on sustained speech on iPhone while medium drifts when the encoder cannot keep up. Native streaming architecture, designed for sub two hundred fifty millisecond time to first token. The dot ort weights ship as data and there is no Core ML compile step at first launch.

The third decision was a voice activity gate plus small live speech recognition for real time iPhone capture. The alternatives were medium continuously and accept the lag, or medium on background priority and let it drift. The medium build can drift below real time on continuous audio. The energy gate sheds silence frames that account for forty to sixty percent of conversational audio.

The fourth decision was hybrid retrieval combining dense and BM25 with Reciprocal Rank Fusion, instead of pure dense. NLContextual averages token vectors and loses keyword precision, so a question with a specific proper noun can rank a paraphrased chunk with the wrong name higher. BM25 ranks by exact keyword overlap weighted by inverse document frequency. RRF with k equals sixty is the production standard for combining ranked lists at different score scales.

The fifth decision was the full transcript shortcut for short meetings, retrieval only for long ones. A five to seven minute transcript is six hundred to twelve hundred tokens and fits in the language model prompt with room to spare. When the entire transcript reaches the language model, retrieval failure modes become impossible. Retrieval only kicks in above the ten thousand character threshold.

The sixth decision was NLContextualEmbedding instead of gte small Core ML. The system asset ships zero bytes in the bundle. The embedding service sits behind a protocol so the swap is a one file change. For a seven day take home, buying back the bundle size was worth a small recall hit, and the hybrid retrieval design is partly a mitigation for the recall gap.

The seventh decision was SwiftDataVectorStore with in process cosine, not sqlite vec. For hundreds of chunks across a handful of meetings, the cosine pass runs in under five milliseconds. The vector store sits behind a protocol so the swap to sqlite vec is a one file change when corpus size justifies it.

The eighth decision was hold to talk only, no automatic barge in. Auto barge in requires perfect echo cancellation and Apple's voice processing IO unit is good but not perfect. Kokoro tail bleed past the cancellation consistently fired the barge in gate, which then opened a six second microphone window that the recognizer happily transcribed as nonsense. Hold to talk uses the user's button hold as the speech indicator, which is unambiguous and zero false positive.

The ninth decision was that the embedding fallback throws and the pipeline tolerates per row failure. On a fresh airplane mode device, the system asset can be missing. Hard failing meant the entire pipeline broke until the device connected to network. The fallback throws, the pipeline catches and persists chunks with dimension zero, the retriever skips dimension mismatched rows, the chat shows a banner, and the repair tool re-embeds those rows when the service comes back.

The tenth decision was the diarization clustering threshold of zero point five with an oversample then collapse cleanup. The default of zero point seven collapsed similar voices into one speaker. Zero point five splits real speakers reliably but produces ghost clusters that the cleanup pass folds into the nearest non ghost centroid.

The eleventh decision was the measurement audio session mode for recording, not voiceChat or videoRecording. Whisper class speech recognition was trained on relatively unprocessed audio and the voice processing IO unit measurably degrades word error rate on free form transcription. Measurement gives the cleanest signal at the cost of leaving echo cancellation off, which is fine because the recording surface is hold to record with no concurrent text to speech.

The twelfth decision was honest time to first spoken word measurement, microphone release to first synthesis dispatch. The measurement should be honest about what it covers. Microphone release to first sentence handed to the synth chain is what we can measure deterministically. Kokoro adds another two hundred fifty to three hundred milliseconds of first audio chunk latency that we cannot measure without a callback FluidAudio does not expose. We report what we can prove and document the gap inline.

The thirteenth decision was that background diarization is deferred because polish and diarize already run concurrently. The async let pattern in the meeting processing pipeline already runs both in parallel. On a warm device, diarize completes before polish on a typical meeting. Fully background diarize would help only on long meetings where diarize is slower than polish, or on cold start which is amortized by the prewarm task.

The fourteenth decision was that the far field recording profile is plumbed but not user toggleable. Far field capture is microphone physics limited and software profiles alone will not deliver lecture hall accuracy. The structural plumbing is in place behind RecordingProfile cases so a future adaptive automatic gain control commit can flip the toggle without restructuring the code.

The fifteenth decision was that tests live for the riskiest pure logic, not for view code. Thirty nine unit tests across five suites cover the modules where a regression is invisible at runtime. SwiftUI XCUITest is fragile and rarely catches real regressions for an indie codebase this size.

# Part Ten — What Was Deferred and Why

A take home that ships every researched idea is a take home that does not ship. The application explicitly defers a number of architectural upgrades that were considered, prototyped in some cases, and consciously kept out of the submission because the marginal benefit did not justify the risk inside seven days.

Moshi swift, the full duplex on device language model, was researched and rejected. The two gigabyte quantized model size and a barge in score of thirty five out of one hundred on the FD Bench paper, compared to seventy nine plus for the planned discrete pipeline, made it the wrong fit for a take home submission.

Speculative decoding for speech recognition was researched and rejected. Apple's own Recurrent Drafter research showed a net loss for Whisper class encoders, and Argmax explicitly omitted it from WhisperKit. The implementation cost was not justified.

ColBERT and other late interaction retrieval methods were researched and rejected. There is no iOS port and per token embedding storage explodes for ten thousand chunks. The community port can be adopted later if it matches the vector store protocol.

HyDE query rewriting was researched and rejected. The forty to sixty millisecond latency add per query is not worth the marginal recall gain on conversational question and answer.

BitNet at one point five eight bits was researched and rejected. There is no iOS native support yet.

GraphRAG and HippoRAG entity graphs were researched and rejected. There is no mobile implementation, and language model in loop entity extraction at index time would be a battery hit.

Apple SpeechAnalyzer at iOS 26 was researched and rejected. The eight percent word error rate compared to seven percent for Moonshine is marginal, and the brief explicitly discouraged Apple Speech Models.

Long context windows of fifty thousand tokens or more, instead of retrieval, are not optional. Foundation Models is hard capped at four kilo tokens. Long context is not on the iOS 26 menu.

MLX Swift with Qwen seven billion as the language model was researched and rejected. Two to four tokens per second on iPhone is too slow for question and answer. If Foundation Models becomes unavailable, the swap is to MLX Swift with Phi 4 mini at three point eight billion parameters and six to ten tokens per second.

TEN VAD and Pipecat SmartTurnV3 for full duplex turn detection were researched and deferred. They would shave two hundred to four hundred milliseconds off the perceived latency and bring the application into Gemini Live conversational territory, but the demo path uses hold to talk which makes the precision matter less. The energy gate plus hold to talk pattern is the right submission, and the SmartTurn upgrade is documented for the hardening sprint.

# Part Eleven — Test and Performance Summary

The unit test suite runs forty five tests across seven suites in roughly one hundred fifty milliseconds on the iPhone 17 Pro Max simulator. Coverage focuses on the modules where a regression would be invisible at runtime — the energy voice activity gate's frame decision logic, the sentence boundary detector's cursor invariants, the meeting title sanitizer's filler stripping, the BM25 index's tokenization, the Reciprocal Rank Fusion implementation including the BM25 only hit survival case, the global Q&A router's deterministic intents, the spoken TTS sanitizer including contraction and possessive preservation so Kokoro pronounces "don't" and "Andre's" correctly, and the diarization service's spurious cluster collapse including the ghost cycle bug regression. Every commit runs the suite before push.

Performance is sampled by an in process SessionPerfSampler that writes a CSV at every recording. The CSV captures timestamps, memory, central processing unit, thermal state, and battery delta over the session. The repository ships a real device capture from a twenty minute iPhone 17 Pro Max session — recording plus question and answer — under perf slash aftertalk dash perf dash twenty thousand twenty six oh four thirty dash twenty min dot png. Memory peaked around two point three gigabytes and settled around one point seven gigabytes during the run. CPU averaged forty one percent of one core. Thermal stayed in the fair band for the recording itself and stepped briefly to serious during Kokoro heavy question and answer turns. The phone was on charger so battery delta is not a usable reading from this capture. The thirty minute recording plus ten minute question and answer off charger session is the canonical run we would ship for a v one review and is still on the open list for the demo day capture.

# Part Twelve — What I Would Build Next

The current application is the right surface area for a take home submission. With another two weeks of focused work, three things would meaningfully improve the product. The first is Silero v5 voice activity replacing the energy gate, with TEN VAD plus SmartTurn turn detection layered on top. This brings the perceived response latency down by two to four hundred milliseconds and opens the door to a real auto interrupt that does not misfire on Kokoro tail bleed. The second is gte small Core ML for embeddings, behind a runtime A B test against NLContextualEmbedding on a golden retrieval set. If the recall lift justifies the fifty megabyte bundle weight, the swap ships. The third is FluidAudio's OfflineDiarizerManager with VBx clustering for offline file diarization. The current Pyannote setup is online and degrades on long meetings; offline diarization with constrained clustering is the documented next step.

A v2 of the application would also add a settings surface for the far field recording profile, with adaptive automatic gain control that ramps gain into reverb without amplifying room noise into hallucinations. That requires a corpus of real classroom recordings to A B against, which the take home does not have.

# Part Thirteen — Closing Thoughts

The take home rewards depth over breadth. Every reviewer can see a candidate ship the required functional requirements. Few candidates ship every stretch goal, write a runtime privacy assertion that fires loudly when the application drifts, audit their own Logger calls to remove user content leaks, document fifteen architectural decisions with their alternatives and rationales, and run forty three unit tests that focus on the riskiest pure logic. The bet is that an interviewer at AirCaps would rather see the engineering judgment behind those choices than the surface gloss of a polished demo.

The application also tells a story about how this engineer thinks. The grounding gate is carried over from CS Navigator v5, an earlier production project that audited fourteen hundred and fifty student chats. The pre computed speaker cards pattern is borrowed from the same project's Course Context Engine. The skill design language is borrowed from production agentic skills shipped to one hundred and twenty installs. Aftertalk is the first time these patterns run end to end on a phone with no cloud, and the through line is worth telling — the same gate that prevents hallucination at scale prevents Aftertalk from making up meeting decisions.

The deadline is three days out. The code is on origin main. The build is green. The forty three tests pass. The privacy claim is auditable. The TTS playback path is hardened with a conservative audio route and spoken-text sanitizer. The chat dock takes typed input and spoken input through the same code path. The citation pills jump to the source span. The repair tool fixes embeddings when the system asset is missing. The README has the demo gif, the architecture diagram, the component table, the build instructions, and the honest tradeoff section. Submission is ready when the demo video is recorded.

# Appendix — Quick Reference

## Models in the bundle

The application bundle ships three model assets — Moonshine small streaming as ONNX weights at roughly fifty megabytes, Parakeet TDT zero point six billion v two as Core ML at roughly four hundred megabytes, and Pyannote three point one with WeSpeaker v two as Core ML at roughly thirty megabytes. Foundation Models, NLContextualEmbedding, and Kokoro 82M are downloaded on first launch from FluidAudio and Apple system asset providers respectively, so the bundle ships those at zero bytes.

## Critical files

The pipeline lives in roughly thirty Swift files. The most important ones to read are AftertalkApp.swift for the lifecycle, RecordingViewModel.swift for the capture loop, MeetingProcessingPipeline.swift for the polish, diarize, chunk, embed, summarize chain, QAOrchestrator.swift for the question and answer flow, KokoroTTSService.swift and TTSWorker.swift for the text to speech path, HierarchicalRetriever.swift and ContextPacker.swift for the retrieval design, PrivacyMonitor.swift for the runtime privacy assertion, and ChatThreadView.swift and GlobalChatView.swift for the chat surfaces.

## Repository

The public repository lives at github dot com slash theaayushstha1 slash aftertalk under the MIT license. The commit history tells the day by day story — Day 0 is the foundation work, Day 1 is the streaming Moonshine ASR, Day 2 is the structured summary and retrieval, Day 3 is the voice question and answer loop with the grounding gate, Day 4 is Kokoro neural text to speech and Pyannote diarization, Day 5 is the cross meeting global chat, Day 6 is polish and profiling, Day 7 is submission. Each commit message follows the conventional commits format and credits the engineer plus the tooling that helped.

## Sign off

Aftertalk is a personal experiment in fully on device meeting intelligence. Built in seven days during finals week. Open source. MIT licensed. Nothing leaves the device.
