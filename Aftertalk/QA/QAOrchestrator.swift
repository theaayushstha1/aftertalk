import Foundation
import FoundationModels
import os

enum QAStage: Equatable, Sendable {
    case idle
    case retrieving
    case generating
    case speaking
    case done
    case failed(String)
}

struct QAResult: Sendable {
    let question: String
    let answer: String
    let citations: [ChunkCitation]
    let groundedByLLM: Bool
    let ttfswMillis: Double?
    let totalMillis: Double
}

enum QAError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case retrievalFailed(any Error)
    case generationFailed(any Error)

    var description: String {
        switch self {
        case .modelUnavailable(let why): "Foundation Models unavailable: \(why)"
        case .retrievalFailed(let e): "Retrieval failed: \(e)"
        case .generationFailed(let e): "Generation failed: \(e)"
        }
    }
}

@MainActor
@Observable
final class QAOrchestrator {
    var stage: QAStage = .idle
    var liveAnswer: String = ""

    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "QA")
    private let retriever: any Retriever
    private let packer: ContextPacker
    private let tts: any TTSService
    private let bargeIn = BargeInController()
    private var inFlight: Task<QAResult?, Never>?
    /// Set the moment the user's voice trips the energy gate during TTS
    /// playback. Surfaced through `didBargeIn` so the chat UI can render a
    /// "you interrupted, hold to ask again" banner. Cleared either by the
    /// next ask starting (top of `runAsk`/`runAskGlobal` reset) or by the
    /// view explicitly calling `clearBargeIn()` when the user begins a fresh
    /// hold gesture (so the banner disappears the moment listening starts).
    var didBargeIn: Bool = false

    /// View-side callback fired immediately after a barge-in completes its
    /// cancel(). Lets the chat surface auto-restart ASR for a short listen
    /// window so the user doesn't have to find the mic button again — they
    /// just keep talking after interrupting. Setting this to `nil` (or never
    /// installing it) preserves the manual barge-in behavior: cancel only,
    /// banner shows, user holds-to-ask again.
    ///
    /// Why a closure instead of a Bool flag: re-arming requires taking over
    /// the view's `holding` state + scheduling an auto-finalize timer, which
    /// is genuinely view-layer work. Pushing that into the orchestrator would
    /// drag QuestionASR + the chat thread's repository into this file. The
    /// closure boundary keeps the orchestrator focused on retrieve → LLM →
    /// TTS and lets each chat surface own its own re-arm policy (per-meeting
    /// chat vs global cross-meeting chat both install the same handler today
    /// but they could diverge later — global chat might want a longer window
    /// for example).
    var onAutoRearm: (@MainActor () async -> Void)?
    /// Ordered chain of speech tasks. Completed LLM sentences first flow
    /// through `pendingSpeechText`, which coalesces short adjacent sentences
    /// into one Kokoro utterance. Without that, answers sound like a playlist
    /// of tiny clips: every sentence gets its own model attack/tail and the
    /// player can underrun while the next sentence synthesises. The chain still
    /// preserves order by awaiting the previous task before calling `tts.speak`.
    ///
    /// We track *every* task, not just the tail, so `cancel()` can stop all
    /// of them. A previous version cancelled only the tail — predecessors
    /// kept running their synthesis + enqueue, so a tap on the mic to
    /// interrupt the answer dropped the current player buffer but the next
    /// chunk that finished synthesising one beat later still played, making
    /// the cancel feel unresponsive.
    private var speechTasks: [Task<Void, Never>] = []
    private var pendingSpeechText: String = ""

    /// Keep chunks under the Kokoro 5s graph budget. We pin Kokoro to the 5s
    /// variant in `KokoroTTSService` so a long acronym-dense sentence with no
    /// internal commas would otherwise either truncate or throw — at 24 kHz,
    /// 5 s is ~120 k samples, which is roughly 130–150 chars at typical
    /// English phoneme density. 130 target / 150 max gives the audio path
    /// enough material to mask sentence seams while staying under the graph
    /// ceiling on dense answers (an earlier 185 ceiling tripped the limit
    /// in review).
    private static let smoothSpeechTargetChars = 130
    private static let smoothSpeechMaxChars = 150

    /// Cosine similarity floor below which we treat the question as off-topic
    /// and refuse to call the LLM (CS Navigator grounding-gate pattern). 0.4
    /// was the original guess; in real Day-4 testing on iPhone 17 Pro Max
    /// against the golden 5-min meeting, on-topic questions consistently
    /// scored 0.28–0.45 with NLContextualEmbedding (gte-small produces tighter
    /// scores). 0.4 was rejecting real questions and producing the "single
    /// disclaimer sentence and stop" symptom. Lowered to 0.22 — well below
    /// every legitimate match observed and still safely above noise.
    /// Lowered from 0.22 → 0.10 because `NLContextualEmbedding`'s cosine
    /// similarity sits in a tighter range than gte-small (the embedding
    /// the threshold was originally tuned against): related-topic pairs
    /// score ~0.30-0.50 instead of ~0.50-0.80, and broad-question pairs
    /// can fall to ~0.15. The previous 0.22 threshold caused the gate to
    /// fire on legitimate "what did we discuss" questions. The soft-gate
    /// changes in `runAsk` and `runAskGlobal` are the real fix; this
    /// just makes the threshold honest about what NLContextual produces.
    private let groundingThreshold: Float = 0.10

    nonisolated private static let globalOverviewHeaderLimit = 12

    /// Hard cap on spoken sentences. The brief asks for ~3-5 sentence answers,
    /// but soft-wraps + commas can split a single thought into multiple emitted
    /// "sentences" so we leave headroom.
    private let maxSpokenSentences: Int = 10

    private static let globalSystemInstructions = """
    You are a meeting assistant answering a question across multiple recorded meetings on the user's phone. Each excerpt is tagged with its source meeting title and timestamp. Your answer is read aloud, so write it the way a person would speak it — natural, conversational, in your own words.

    How to answer:
    - If excerpts from two or more meetings genuinely contribute to the answer, synthesize across them and you may briefly mention the meetings ("in the standup and the planning sync, ...").
    - If only one meeting actually contains the answer, just answer naturally — do NOT enumerate other meetings or hint that you looked at them. Naming meetings the user did not ask about feels like noise.
    - When the question references a specific meeting (a topic, a speaker, a date), keep the answer scoped to that meeting unless other meetings clearly pertain.
    - Use the "Meeting overviews" block as the trusted backbone — it lists each meeting's topics, decisions, action items. Use the "Excerpts" for specifics and grounding.
    - If any overview or excerpt is relevant, answer from that context even when the answer is partial. Do not refuse just because every meeting is not represented in the retrieved excerpts.
    - Length: three to five short sentences of plain prose, around 12 to 18 words each. The answer is read aloud sentence by sentence — long run-on sentences sound stilted and break the speech rhythm. No bullet points, no numbered lists, no dashes, no asterisks, no markdown.
    - Speakers are not pre-labeled. Names from the transcript may be misheard — say "the team" or "two people" rather than guessing if you're unsure.
    - Never invent decisions, dates, owners, or meetings that are not in the context.
    - Do not preface with "Based on the meetings" or "According to the context." Just answer.
    - If the context does not contain the exact fact requested, say that specific fact was not found, then mention the closest related context if it is useful. The app handles truly empty context before you are called.
    """

    private static let systemInstructions = """
    You are a meeting assistant. The user asks a question and you answer using the meeting context provided. Your answer is read aloud, so write it the way a person would speak it — natural, conversational, in your own words.

    Two kinds of context arrive together. The "Meeting overview" block is a structured digest already extracted from the full transcript: topics, decisions, action items, open questions. Treat it as the trusted backbone of your answer. The "Excerpts" below it are individual transcript moments retrieved by relevance — use them to add specifics, quotes-in-your-own-words, and grounding for any claim you make.

    How to answer:
    - For broad questions ("what did they discuss", "summarize", "what was decided"), lead with the overview. Pull the matching topics or decisions and explain them in plain prose, citing specifics from the excerpts where helpful.
    - For specific questions ("what did X commit to", "did they decide Y"), search both the overview and the excerpts; if the overview captures it, name the relevant action item or decision.
    - Synthesize. Connect related items into one coherent paragraph. Do not paste excerpts verbatim or use quotation marks around transcript text.
    - Length: three to five short sentences of plain prose, around 12 to 18 words each. The answer is read aloud sentence by sentence — long run-on sentences sound stilted and break the speech rhythm. No bullet points, no numbered lists, no dashes, no asterisks, no markdown, no headings, no code blocks. Sentences with periods only.
    - Speakers are not pre-labeled. Names you see in the transcript come from the audio and may be misheard, especially unusual names or self-introductions. If the user asks who was in the meeting and you are not confident a name is correct, say "the speakers" or "two people" rather than guessing. Never invent a name that is not in the context.
    - Never invent decisions, dates, owners, or numbers that are not in the context.
    - Do not preface with "Based on the context" or "According to the meeting." Just answer.
    - If neither the overview nor the excerpts answer the question, reply with exactly: I don't have that in the meeting transcripts.
    """

    init(retriever: any Retriever, packer: ContextPacker = ContextPacker(), tts: any TTSService) {
        self.retriever = retriever
        self.packer = packer
        self.tts = tts
    }

    /// Cancels any in-flight ask: drops queued TTS, cancels the LLM stream task,
    /// and resets the orchestrator to `.idle` so the next press starts clean.
    /// Safe to call when nothing is in flight.
    func cancel() async {
        inFlight?.cancel()
        inFlight = nil
        // Cancel every task in the speech chain, not just the tail. Each
        // task carries its own Task.isCancelled state that the underlying
        // `speak` checks after synthesis returns, so this is what makes a
        // mid-answer mic-tap actually silence the assistant.
        for t in speechTasks { t.cancel() }
        speechTasks.removeAll()
        pendingSpeechText = ""
        bargeIn.stop()
        await tts.stop()
        liveAnswer = ""
        stage = .idle
    }

    /// Arm the auto barge-in listener for the duration of TTS playback. When
    /// the user's voice trips the energy gate we cancel the LLM stream + TTS
    /// queue and flag `didBargeIn` so the chat UI can prompt the user to ask
    /// again. Idempotent: re-arming while already armed is a no-op (the
    /// controller resets internally).
    ///
    /// After cancellation completes we invoke `onAutoRearm` (if set) so the
    /// chat surface can immediately reopen QuestionASR for a short listen
    /// window. The callback is awaited in-line so the auto-rearm flow runs
    /// after the speech chain has fully torn down — re-arming concurrently
    /// with `cancel()` would race the AudioSessionManager flip from
    /// spoken-audio playback back to `.measurement` (clean ASR).
    private func armBargeIn() {
        // Auto barge-in is intentionally disabled. The energy-based gate at
        // -32 dB / 180 ms hold misfires on Kokoro tail bleed past Apple's AEC
        // (especially on speaker output), and the auto-rearm path then opens
        // a 6 s mic window that ASR happily transcribes — feeding garbage
        // back as the user's "next question." We're keeping hold-to-talk as
        // the only interrupt mechanism (TEN-VAD + SmartTurnV3 deferred; see
        // BargeInController.swift). The BargeInController + onAutoRearm
        // plumbing stays so swapping back is a one-line change.
        log.debug("armBargeIn no-op (energy gate disabled, hold-to-talk only)")
    }

    /// Reset the `didBargeIn` flag so the chat UI's "you interrupted" banner
    /// disappears. Called from the chat surfaces' `beginHold` so a fresh
    /// hold gesture clears the banner before the listening row replaces it
    /// (instead of showing both stacked).
    func clearBargeIn() {
        didBargeIn = false
    }

    /// Flip the audio session from clean-listening (`.measurement`) to a
    /// high-quality spoken-audio playback route. Auto barge-in is disabled,
    /// so keeping `.voiceChat` AEC active during Kokoro playback just adds
    /// phone-call DSP artifacts without giving us interruption behavior.
    private func enterSpeakingSession() async {
        do {
            try await AudioSessionManager.shared.configureForSpeechPlayback()
        } catch {
            log.warning("session flip to speech playback failed: \(String(describing: error), privacy: .public) — continuing with current mode")
        }
    }

    /// Add `sentence` to the smooth speech buffer. Returns true only when a
    /// Kokoro utterance was actually dispatched; callers use that for TTFSW.
    @discardableResult
    private func speakChained(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if pendingSpeechText.isEmpty {
            pendingSpeechText = trimmed
        } else {
            let combined = pendingSpeechText + " " + trimmed
            if combined.count <= Self.smoothSpeechMaxChars {
                pendingSpeechText = combined
            } else {
                let didDispatch = flushPendingSpeechBuffer()
                pendingSpeechText = trimmed
                if pendingSpeechText.count >= Self.smoothSpeechTargetChars {
                    return flushPendingSpeechBuffer() || didDispatch
                }
                return didDispatch
            }
        }

        guard pendingSpeechText.count >= Self.smoothSpeechTargetChars
                || pendingSpeechText.hasSuffix("?")
                || pendingSpeechText.hasSuffix("!") else {
            return false
        }
        return flushPendingSpeechBuffer()
    }

    private func flushPendingSpeechBuffer() -> Bool {
        let text = pendingSpeechText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSpeechText = ""
        guard !text.isEmpty else { return false }
        appendSpeechTask(text)
        return true
    }

    /// Append `text` to the ordered speech chain and return immediately. The
    /// caller keeps draining the LLM stream while Kokoro synthesises this chunk
    /// in the background.
    private func appendSpeechTask(_ text: String) {
        let prev = speechTasks.last
        let svc = tts
        let task = Task { [prev] in
            if let prev { _ = await prev.value }
            if Task.isCancelled { return }
            await svc.speak(text)
        }
        speechTasks.append(task)
    }

    /// Wait for every queued sentence in the chain to finish synthesising +
    /// being scheduled on the player. Used by the orchestrator after the LLM
    /// stream completes so we don't tear down `liveAnswer` mid-playback.
    @discardableResult
    private func awaitSpeakChain() async -> Bool {
        let didFlushPending = flushPendingSpeechBuffer()
        let tasks = speechTasks
        speechTasks.removeAll()
        for t in tasks { _ = await t.value }
        return didFlushPending
    }

    /// Lazy-warm the TTS pipeline. Called from ChatThreadView.task so Kokoro's
    /// ~300 MB CoreML graph loads only when the user opens a chat tab — not at
    /// app launch alongside the Foundation Models LLM (~3 GB). Stacking both at
    /// launch was tipping iPhone Air over the iOS 26 foreground jetsam ceiling.
    /// Idempotent: KokoroTTSService.warm() early-returns once isAvailable.
    func warmTTS() async {
        do {
            try await tts.warm()
        } catch {
            log.warning("TTS warm failed: \(String(describing: error), privacy: .public) — will lazy-warm on first speak")
        }
    }

    /// Tear down TTS and free the underlying model bytes. Called from
    /// MeetingDetailView.onDisappear so leaving a meeting drops Kokoro's
    /// CoreML graphs back to disk. Safe to call when nothing is loaded.
    func cleanupTTS() async {
        await tts.cleanup()
    }

    /// Replays an already-generated answer through the TTS pipeline. Used by
    /// the chat bubble's speaker affordance so the user can re-listen to a
    /// previous Kokoro response without re-running the LLM. Splits on sentence
    /// boundaries so streaming TTS still works. Cancels any in-flight ask
    /// first to avoid two voices overlapping.
    func replay(_ text: String) async {
        await cancel()
        var detector = SentenceBoundaryDetector()
        let sentences = detector.feed(text) + detector.finalize(text)
        guard !sentences.isEmpty else { return }
        stage = .speaking
        await enterSpeakingSession()
        for sentence in sentences {
            if Task.isCancelled { break }
            _ = speakChained(sentence)
        }
        _ = await awaitSpeakChain()
        stage = .idle
    }

    /// `releasedAt` should be the moment the user's mic-release happened —
    /// i.e. the timestamp captured *before* `QuestionASR.stop()` runs its
    /// 600 ms silence pad + final-delta wait. When supplied, TTFSW is
    /// measured from that point instead of "first LLM snapshot," which is
    /// the honest definition the AirCaps brief asks for. When nil (legacy
    /// callers, replays, snapshot tests) we fall back to first-snapshot
    /// timing so the field still has a value.
    func ask(question: String, in meeting: Meeting, releasedAt: ContinuousClock.Instant? = nil) async -> QAResult? {
        await cancel()
        let task = Task<QAResult?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.runAsk(question: question, in: meeting, releasedAt: releasedAt)
        }
        inFlight = task
        return await task.value
    }

    /// Cross-meeting Q&A: lets the hierarchical retriever fire its Layer-1
    /// summary search to pick the most relevant meetings, then runs Layer-2
    /// chunk search inside that scope. The overview block is assembled from
    /// the matched meetings' structured summaries — different prompt frame
    /// from the per-meeting path because there is no single "this meeting"
    /// to anchor against.
    func askGlobal(question: String, repository: MeetingsRepository, releasedAt: ContinuousClock.Instant? = nil) async -> QAResult? {
        await cancel()
        let task = Task<QAResult?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.runAskGlobal(question: question, repository: repository, releasedAt: releasedAt)
        }
        inFlight = task
        return await task.value
    }

    /// Char count under which we skip RAG entirely and put the whole
    /// transcript + summary in the LLM prompt. ~10 000 chars ≈ ~2500
    /// tokens — comfortably below Foundation Models' 4096 cap once the
    /// system prompt (~250) and generation reserve (~1200) are subtracted.
    /// Most 5-7 minute recordings fit easily; longer meetings fall back
    /// to the retrieval path. Char count is used instead of
    /// `Session.tokenCount(_:)` to avoid a synchronous tokenization call
    /// before we even know which path we're taking.
    private static let fullTranscriptCharBudget = 10_000

    private func runAsk(question: String, in meeting: Meeting, releasedAt: ContinuousClock.Instant? = nil) async -> QAResult? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        stage = .retrieving
        liveAnswer = ""
        didBargeIn = false
        let totalStart = ContinuousClock.now

        // Full-transcript path. When the recording is short enough that
        // its entire transcript fits in one Foundation Models prompt with
        // headroom, retrieval is pure ceremony — and a failure surface.
        // Skip it. The LLM gets the full transcript verbatim plus the
        // structured summary, so every demo question on a typical 5-7
        // minute meeting becomes answerable from the actual recording
        // instead of hostage to embedding similarity. Longer meetings
        // fall through to the retrieval path below.
        let transcriptCharCount = meeting.fullTranscript.count
        if transcriptCharCount > 0, transcriptCharCount <= Self.fullTranscriptCharBudget {
            log.info("runAsk: using full-transcript path (transcript=\(transcriptCharCount, privacy: .public) chars)")
            return await runAskFullTranscript(
                question: trimmed,
                meeting: meeting,
                totalStart: totalStart,
                releasedAt: releasedAt
            )
        }

        let retrieval: RetrievalResult
        do {
            retrieval = try await retriever.retrieve(
                RetrievalQuery(text: trimmed, scopedToMeeting: meeting.id, topKChunks: 8)
            )
        } catch {
            log.error("retrieve failed: \(String(describing: error), privacy: .public)")
            stage = .failed("retrieve: \(error)")
            return nil
        }

        log.info("retrieve: chunks=\(retrieval.chunks.count, privacy: .public) topScore=\(retrieval.topScore, privacy: .public) threshold=\(self.groundingThreshold, privacy: .public)")

        // Soft grounding gate. We only fire the disclaimer when retrieval
        // came up empty AND there's no structured summary to fall back on.
        // The previous hard gate (`topScore < threshold` → disclaimer) was
        // wrong for broad questions like "what did we discuss?" — it
        // refused before the LLM ever saw the structured summary that
        // already contains the answer. Now: if a summary exists, always
        // call the LLM with summary + best-effort chunks; only refuse on
        // a meeting that genuinely has no structured context yet.
        let hasSummary = (meeting.summary != nil)
        if retrieval.isEmpty && !hasSummary {
            log.warning("grounding gate fired (no chunks AND no summary) — speaking disclaimer")
            let disclaimer = "I don't have that in the meeting transcripts."
            stage = .speaking
            liveAnswer = disclaimer
            await enterSpeakingSession()
            armBargeIn()
            await tts.speak(disclaimer)
            bargeIn.stop()
            let elapsed = totalStart.duration(to: .now).aftertalkMillis
            liveAnswer = ""
            stage = .idle
            return QAResult(
                question: trimmed,
                answer: disclaimer,
                citations: [],
                groundedByLLM: false,
                ttfswMillis: nil,
                totalMillis: elapsed
            )
        }

        let session = LanguageModelSession(instructions: Self.systemInstructions)
        do {
            try checkAvailability()
        } catch {
            stage = .failed("\(error)")
            return nil
        }

        let packed = packer.pack(meetingTitle: meeting.title, chunks: retrieval.chunks, session: session)
        let overviewBlock = Self.overview(for: meeting).map { "Meeting overview:\n\($0)\n\n" } ?? ""
        let prompt = """
        Question: \(trimmed)

        \(overviewBlock)Excerpts (sorted by relevance):

        \(packed.prompt)
        """

        stage = .generating
        var detector = SentenceBoundaryDetector()
        var lastSnapshot = ""
        // `ttfswStart` is the honest reference for time-to-first-spoken-word:
        // the moment the user released the mic. Falls back to first-LLM-
        // snapshot only when callers haven't instrumented the release point
        // (legacy / test paths). The end of the measurement is the moment
        // we hand the *first sentence* to the TTS synth chain — what we
        // call "first synth dispatch." Kokoro adds another ~250-300 ms
        // before audio actually leaves the speaker; that gap is documented
        // alongside the metric and not folded into the number itself,
        // because we don't have a Kokoro first-chunk callback to measure it.
        var ttfswStart: ContinuousClock.Instant? = releasedAt
        var ttfswMillis: Double?
        var spokenCount = 0

        do {
            let stream = session.streamResponse(to: prompt)
            outer: for try await snapshot in stream {
                if Task.isCancelled { break }
                let text = snapshot.content
                guard text != lastSnapshot else { continue }
                lastSnapshot = text
                liveAnswer = text
                if ttfswStart == nil { ttfswStart = .now }

                let sentences = detector.feed(text)
                if !sentences.isEmpty, stage != .speaking {
                    stage = .speaking
                    await enterSpeakingSession()
                    armBargeIn()
                }
                for sentence in sentences {
                    if Task.isCancelled { break outer }
                    // Cap the spoken voice but let the model keep streaming
                    // text — the chat bubble shows the full answer even after
                    // the speaker goes quiet.
                    if spokenCount >= maxSpokenSentences { break }
                    log.info("speak[\(spokenCount + 1, privacy: .public)/\(self.maxSpokenSentences, privacy: .public)] chain: chars=\(sentence.count, privacy: .public)")
                    let didDispatch = speakChained(sentence)
                    spokenCount += 1
                    if ttfswMillis == nil, didDispatch, let start = ttfswStart {
                        ttfswMillis = start.duration(to: .now).aftertalkMillis
                    }
                }
            }
            if !Task.isCancelled, spokenCount < maxSpokenSentences {
                let trailing = detector.finalize(lastSnapshot)
                if !trailing.isEmpty {
                    log.info("stream finalize: \(trailing.count, privacy: .public) trailing fragments after spokenCount=\(spokenCount, privacy: .public)")
                }
                for sentence in trailing {
                    if spokenCount >= maxSpokenSentences { break }
                    log.info("speak[trailing] chain: chars=\(sentence.count, privacy: .public)")
                    if !sentence.isEmpty, stage != .speaking {
                        stage = .speaking
                        await enterSpeakingSession()
                        armBargeIn()
                    }
                    let didDispatch = speakChained(sentence)
                    spokenCount += 1
                    // Some answers complete before the streaming detector
                    // sees a sentence-final punctuation token — the FIRST
                    // sentence then arrives only via this `finalize` path.
                    // Without setting `ttfswMillis` here the metric stays
                    // nil and we silently report "no TTFSW" for those turns.
                    if ttfswMillis == nil, didDispatch, let start = ttfswStart {
                        ttfswMillis = start.duration(to: .now).aftertalkMillis
                    }
                }
            }
            log.info("stream complete: spokenCount=\(spokenCount, privacy: .public) answerLen=\(lastSnapshot.count, privacy: .public)")
        } catch {
            log.error("generate failed: \(String(describing: error), privacy: .public)")
            stage = .failed("generate: \(error)")
            return nil
        }

        if Task.isCancelled {
            await tts.stop()
            liveAnswer = ""
            stage = .idle
            return nil
        }

        // Drain the speech chain so the result returns only after every
        // sentence is at least handed to the player. We don't await actual
        // audio completion (that'd block the UI for ~3 s per sentence) — just
        // synthesis + scheduleBuffer, which is what makes the playback feel
        // continuous from the user's side.
        let didFlushSpeech = await awaitSpeakChain()
        if ttfswMillis == nil, didFlushSpeech, let start = ttfswStart {
            ttfswMillis = start.duration(to: .now).aftertalkMillis
        }
        bargeIn.stop()

        let elapsed = totalStart.duration(to: .now).aftertalkMillis
        let answer = lastSnapshot
        // Clear streaming UI state now that the persisted bubble will own the
        // text. TTS continues playing in the background — that's its own actor.
        liveAnswer = ""
        stage = .idle
        return QAResult(
            question: trimmed,
            answer: answer,
            citations: packed.citations,
            groundedByLLM: true,
            ttfswMillis: ttfswMillis,
            totalMillis: elapsed
        )
    }

    /// Full-transcript Q&A — used when the meeting's transcript fits inside
    /// Foundation Models' prompt budget. Skips retrieval entirely and
    /// hands the LLM the full transcript + structured summary. The LLM
    /// then has every fact in the recording instead of being limited to
    /// whatever embedding similarity surfaced. For ≤7 minute meetings
    /// this turns RAG-related failure modes ("I don't have that," weird
    /// chunks, low recall on broad questions) into a non-issue —
    /// retrieval doesn't run, so it can't be wrong. Citations come back
    /// empty because there are no chunk-level pointers; the chat bubble
    /// renders without citation pills, which is the honest signal that
    /// "everything came from the transcript whole" not "from this
    /// specific chunk."
    private func runAskFullTranscript(
        question: String,
        meeting: Meeting,
        totalStart: ContinuousClock.Instant,
        releasedAt: ContinuousClock.Instant?
    ) async -> QAResult? {
        let session = LanguageModelSession(instructions: Self.systemInstructions)
        do {
            try checkAvailability()
        } catch {
            stage = .failed("\(error)")
            return nil
        }

        // Fire a best-effort retrieval IN PARALLEL with LLM streaming so
        // the chat bubble still gets citation pills. The LLM doesn't see
        // these — its context is the full transcript — but the user does
        // get tappable jump-to-excerpt links for the answers, which were
        // a real reviewer ask. Top 3 to keep the bubble tidy. Falls
        // through with empty citations on retrieval failure rather than
        // delaying the LLM call.
        // Capture `meeting.id` into a local UUID before crossing the
        // async boundary — `Meeting` is a SwiftData @Model and isn't
        // Sendable, so the closure can't directly capture it under
        // Swift 6 strict concurrency.
        let meetingId = meeting.id
        async let citationHits: [ChunkHit] = {
            let result = try? await self.retriever.retrieve(
                RetrievalQuery(text: question, scopedToMeeting: meetingId, topKChunks: 3)
            )
            return result?.chunks ?? []
        }()

        let overviewBlock = Self.overview(for: meeting).map { "Meeting overview:\n\($0)\n\n" } ?? ""
        let prompt = """
        Question: \(question)

        \(overviewBlock)Full meeting transcript:

        \(meeting.fullTranscript)
        """

        stage = .generating
        var detector = SentenceBoundaryDetector()
        var lastSnapshot = ""
        var ttfswStart: ContinuousClock.Instant? = releasedAt
        var ttfswMillis: Double?
        var spokenCount = 0

        do {
            let stream = session.streamResponse(to: prompt)
            outer: for try await snapshot in stream {
                if Task.isCancelled { break }
                let text = snapshot.content
                guard text != lastSnapshot else { continue }
                lastSnapshot = text
                liveAnswer = text
                if ttfswStart == nil { ttfswStart = .now }

                let sentences = detector.feed(text)
                if !sentences.isEmpty, stage != .speaking {
                    stage = .speaking
                    await enterSpeakingSession()
                    armBargeIn()
                }
                for sentence in sentences {
                    if Task.isCancelled { break outer }
                    if spokenCount >= maxSpokenSentences { break }
                    let didDispatch = speakChained(sentence)
                    spokenCount += 1
                    if ttfswMillis == nil, didDispatch, let start = ttfswStart {
                        ttfswMillis = start.duration(to: .now).aftertalkMillis
                    }
                }
            }
            if !Task.isCancelled, spokenCount < maxSpokenSentences {
                let trailing = detector.finalize(lastSnapshot)
                for sentence in trailing {
                    if spokenCount >= maxSpokenSentences { break }
                    if !sentence.isEmpty, stage != .speaking {
                        stage = .speaking
                        await enterSpeakingSession()
                        armBargeIn()
                    }
                    let didDispatch = speakChained(sentence)
                    spokenCount += 1
                    if ttfswMillis == nil, didDispatch, let start = ttfswStart {
                        ttfswMillis = start.duration(to: .now).aftertalkMillis
                    }
                }
            }
        } catch {
            log.error("full-transcript generate failed: \(String(describing: error), privacy: .public)")
            stage = .failed("generate: \(error)")
            return nil
        }

        if Task.isCancelled {
            await tts.stop()
            liveAnswer = ""
            stage = .idle
            return nil
        }

        let didFlushSpeech = await awaitSpeakChain()
        if ttfswMillis == nil, didFlushSpeech, let start = ttfswStart {
            ttfswMillis = start.duration(to: .now).aftertalkMillis
        }
        bargeIn.stop()

        // Pick up the best-effort citations we kicked off above.
        let hits = await citationHits
        let citations = hits.map { c in
            ChunkCitation(
                chunkId: c.chunkId, meetingId: c.meetingId,
                startSec: c.startSec, endSec: c.endSec, speakerName: c.speakerName
            )
        }

        let elapsed = totalStart.duration(to: .now).aftertalkMillis
        liveAnswer = ""
        stage = .idle
        return QAResult(
            question: question,
            answer: lastSnapshot,
            citations: citations,
            groundedByLLM: true,
            ttfswMillis: ttfswMillis,
            totalMillis: elapsed
        )
    }

    private func runAskGlobal(question: String, repository: MeetingsRepository, releasedAt: ContinuousClock.Instant? = nil) async -> QAResult? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        stage = .retrieving
        liveAnswer = ""
        didBargeIn = false
        let totalStart = ContinuousClock.now

        // Global Ask has a few deterministic intents that should never go
        // through RAG. "How many times was AI mentioned?" is an exact database
        // aggregate over full transcripts, not a semantic retrieval problem.
        // "What did my meetings talk about?" is best answered from the
        // structured summaries across the library. Keep these routers narrow:
        // they run before retrieval, so a broad match here can steal real RAG
        // questions.
        do {
            let allHeaders = try await repository.allMeetingHeaders()
            if let term = Self.extractMentionCountTerm(trimmed) {
                do {
                    let counts = try await repository.mentionCounts(for: term)
                    let answer = Self.answerMentionCount(term: term, counts: counts, totalMeetings: allHeaders.count)
                    log.info("global mention-count router hit: termLen=\(term.count, privacy: .public) meetings=\(allHeaders.count, privacy: .public)")
                    return await speakImmediateGlobalAnswer(question: trimmed, answer: answer, totalStart: totalStart)
                } catch {
                    log.warning("global mention-count route failed: \(String(describing: error), privacy: .public) — falling through to retrieval")
                }
            }
            if let overviewAnswer = Self.answerGlobalOverviewQuestion(trimmed, headers: allHeaders) {
                log.info("global overview router hit: qLen=\(trimmed.count, privacy: .public) meetings=\(allHeaders.count, privacy: .public)")
                return await speakImmediateGlobalAnswer(question: trimmed, answer: overviewAnswer, totalStart: totalStart)
            }
            if let metaAnswer = Self.answerMetadataQuestion(trimmed, headers: allHeaders) {
                log.info("global metadata router hit: qLen=\(trimmed.count, privacy: .public) meetings=\(allHeaders.count, privacy: .public)")
                return await speakImmediateGlobalAnswer(question: trimmed, answer: metaAnswer, totalStart: totalStart)
            }
        } catch {
            log.warning("global deterministic router header fetch failed: \(String(describing: error), privacy: .public) — falling through to retrieval")
        }

        let retrieval: RetrievalResult
        do {
            // scopedToMeeting=nil ⇒ HierarchicalRetriever fires Layer 1
            // (summary search) → Layer 2 (chunk search inside top meetings).
            // topKChunks tightened to 6 (vs 8 per-meeting) to leave token
            // headroom for the multi-meeting overview block below.
            retrieval = try await retriever.retrieve(
                RetrievalQuery(text: trimmed, scopedToMeeting: nil, topKChunks: 6)
            )
        } catch {
            log.error("global retrieve failed: \(String(describing: error), privacy: .public)")
            stage = .failed("retrieve: \(error)")
            return nil
        }

        log.info("global retrieve: chunks=\(retrieval.chunks.count, privacy: .public) topScore=\(retrieval.topScore, privacy: .public) threshold=\(self.groundingThreshold, privacy: .public)")

        // Pull baseline meeting summaries up front so we always have
        // structured context to hand the LLM, even when chunk retrieval
        // misses. Previously the overview block was assembled only from
        // meetings that retrieval already hit — if retrieval missed,
        // the LLM saw zero structured context, and the gate fell through
        // to the disclaimer. Now we always include a recent-meetings
        // baseline; retrieval just sharpens which meetings are featured.
        let allHeadersForOverview: [MeetingHeader]
        do {
            allHeadersForOverview = try await repository.allMeetingHeaders()
        } catch {
            log.warning("global header fetch failed: \(String(describing: error), privacy: .public) — proceeding without baseline overview")
            allHeadersForOverview = []
        }

        // Soft grounding gate. We only refuse when retrieval missed AND
        // we have zero meeting summaries to fall back on (genuinely empty
        // device). Otherwise the LLM gets the recent-meetings overview
        // and decides whether the question is answerable from that —
        // exactly what a senior assistant would do given the same
        // context.
        if retrieval.isEmpty && allHeadersForOverview.isEmpty {
            log.warning("global grounding gate fired (no chunks AND no summaries) — speaking disclaimer")
            let disclaimer = "I don't have that across your meetings yet."
            stage = .speaking
            liveAnswer = disclaimer
            await enterSpeakingSession()
            armBargeIn()
            await tts.speak(disclaimer)
            bargeIn.stop()
            let elapsed = totalStart.duration(to: .now).aftertalkMillis
            liveAnswer = ""
            stage = .idle
            return QAResult(
                question: trimmed,
                answer: disclaimer,
                citations: [],
                groundedByLLM: false,
                ttfswMillis: nil,
                totalMillis: elapsed
            )
        }

        // Pull title + structured summary for every meeting represented in
        // the chunk hits, in score order. ContextPacker uses titles for the
        // chunk render lines; the overview block lifts decisions/topics
        // straight from the structured summaries.
        var seenIds = Set<UUID>()
        let citedMeetingIds = retrieval.chunks
            .map(\.meetingId)
            .filter { seenIds.insert($0).inserted }
        // Merge retrieval-cited meetings with the recent-meetings baseline
        // so the overview block always contains *something*. Retrieved
        // meetings come first (they're score-ranked); recent meetings
        // backfill up to a small cap so the multi-meeting block doesn't
        // explode the token budget.
        let baselineHeaders = Array(allHeadersForOverview.prefix(Self.globalOverviewHeaderLimit))
        var headerIndex: [UUID: MeetingHeader] = [:]
        for h in baselineHeaders { headerIndex[h.id] = h }
        let headers: [MeetingHeader]
        if citedMeetingIds.isEmpty {
            headers = baselineHeaders
        } else {
            do {
                let cited = try await repository.meetingHeaders(for: citedMeetingIds)
                for h in cited { headerIndex[h.id] = h }
                // Cited meetings first (preserve score order), then
                // baseline backfill for any not already in.
                var ordered: [MeetingHeader] = []
                var seen: Set<UUID> = []
                for id in citedMeetingIds {
                    if let h = headerIndex[id], seen.insert(id).inserted {
                        ordered.append(h)
                    }
                }
                for h in baselineHeaders where seen.insert(h.id).inserted {
                    ordered.append(h)
                }
                headers = ordered
            } catch {
                log.error("header fetch failed: \(String(describing: error), privacy: .public)")
                headers = baselineHeaders
            }
        }
        let titlesById = Dictionary(uniqueKeysWithValues: headers.map { ($0.id, $0.title) })

        let session = LanguageModelSession(instructions: Self.globalSystemInstructions)
        do {
            try checkAvailability()
        } catch {
            stage = .failed("\(error)")
            return nil
        }

        // Inline meeting title into each chunk render via a tiny shim — the
        // shared ContextPacker takes a single meetingTitle argument, but in
        // global mode every chunk can come from a different meeting. So we
        // pre-render lines per-meeting and concatenate, preserving relevance
        // order across the whole result set.
        let renderedLines = retrieval.chunks.map { c -> String in
            let title = titlesById[c.meetingId] ?? "Unknown meeting"
            let timestamp = String(format: "%02d:%02d", Int(c.startSec) / 60, Int(c.startSec) % 60)
            let speaker = c.speakerName ?? "Unknown speaker"
            return "[\(String(title.prefix(60))) • \(timestamp) • \(speaker)] \(c.text)"
        }
        let citations = retrieval.chunks.map { c in
            ChunkCitation(
                chunkId: c.chunkId, meetingId: c.meetingId,
                startSec: c.startSec, endSec: c.endSec, speakerName: c.speakerName
            )
        }

        let overviewBlock = Self.globalOverview(headers: headers)
        let overviewSection = overviewBlock.isEmpty ? "" : "Meeting overviews:\n\(overviewBlock)\n\n"
        let contextCoverage = """
        Context coverage:
        - Indexed meeting overviews included: \(headers.filter { $0.summary != nil }.count)
        - Retrieved transcript excerpts included: \(renderedLines.count)
        - Treat the overviews as the library-wide baseline, then use excerpts for details.
        - If either block is relevant, answer directly instead of using the fallback sentence.
        """
        let excerptsSection: String
        if renderedLines.isEmpty {
            // Retrieval missed but we have summaries. Tell the LLM
            // explicitly so it doesn't hallucinate excerpts that aren't
            // there — answer from the overview block alone or refuse
            // honestly.
            excerptsSection = "No specific excerpts retrieved. Answer from the overviews above. If the exact fact is missing, say that fact was not found and summarize the closest relevant overview context.\n"
        } else {
            excerptsSection = "Excerpts (sorted by relevance, across multiple meetings):\n\n\(renderedLines.joined(separator: "\n\n"))"
        }
        let prompt = """
        Question: \(trimmed)

        \(contextCoverage)

        \(overviewSection)\(excerptsSection)
        """

        stage = .generating
        var detector = SentenceBoundaryDetector()
        var lastSnapshot = ""
        // Honest TTFSW: anchored to mic-release when caller instrumented it.
        // Same semantics as the per-meeting path — see `runAsk` for details.
        var ttfswStart: ContinuousClock.Instant? = releasedAt
        var ttfswMillis: Double?
        var spokenCount = 0

        do {
            let stream = session.streamResponse(to: prompt)
            outer: for try await snapshot in stream {
                if Task.isCancelled { break }
                let text = snapshot.content
                guard text != lastSnapshot else { continue }
                lastSnapshot = text
                liveAnswer = text
                if ttfswStart == nil { ttfswStart = .now }

                let sentences = detector.feed(text)
                if !sentences.isEmpty, stage != .speaking {
                    stage = .speaking
                    await enterSpeakingSession()
                    armBargeIn()
                }
                for sentence in sentences {
                    if Task.isCancelled { break outer }
                    if spokenCount >= maxSpokenSentences { break }
                    let didDispatch = speakChained(sentence)
                    spokenCount += 1
                    if ttfswMillis == nil, didDispatch, let start = ttfswStart {
                        ttfswMillis = start.duration(to: .now).aftertalkMillis
                    }
                }
            }
            if !Task.isCancelled, spokenCount < maxSpokenSentences {
                let trailing = detector.finalize(lastSnapshot)
                for sentence in trailing {
                    if spokenCount >= maxSpokenSentences { break }
                    if !sentence.isEmpty, stage != .speaking {
                        stage = .speaking
                        await enterSpeakingSession()
                        armBargeIn()
                    }
                    let didDispatch = speakChained(sentence)
                    spokenCount += 1
                    // Mirror of the per-meeting fix: cover the case where
                    // the first speakable sentence only emerges via the
                    // trailing finalize path. Without this, TTFSW silently
                    // reports nil for short / fast answers.
                    if ttfswMillis == nil, didDispatch, let start = ttfswStart {
                        ttfswMillis = start.duration(to: .now).aftertalkMillis
                    }
                }
            }
        } catch {
            log.error("global generate failed: \(String(describing: error), privacy: .public)")
            stage = .failed("generate: \(error)")
            return nil
        }

        if Task.isCancelled {
            await tts.stop()
            liveAnswer = ""
            stage = .idle
            return nil
        }

        let didFlushSpeech = await awaitSpeakChain()
        if ttfswMillis == nil, didFlushSpeech, let start = ttfswStart {
            ttfswMillis = start.duration(to: .now).aftertalkMillis
        }
        bargeIn.stop()

        let elapsed = totalStart.duration(to: .now).aftertalkMillis
        let answer = lastSnapshot
        liveAnswer = ""
        stage = .idle
        return QAResult(
            question: trimmed,
            answer: answer,
            citations: citations,
            groundedByLLM: true,
            ttfswMillis: ttfswMillis,
            totalMillis: elapsed
        )
    }

    private func speakImmediateGlobalAnswer(
        question: String,
        answer: String,
        totalStart: ContinuousClock.Instant
    ) async -> QAResult {
        stage = .speaking
        liveAnswer = answer
        await enterSpeakingSession()
        armBargeIn()
        await tts.speak(answer)
        bargeIn.stop()
        let elapsed = totalStart.duration(to: .now).aftertalkMillis
        liveAnswer = ""
        stage = .idle
        return QAResult(
            question: question,
            answer: answer,
            citations: [],
            groundedByLLM: false,
            ttfswMillis: nil,
            totalMillis: elapsed
        )
    }

    private func checkAvailability() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return
        case .unavailable(let reason): throw QAError.modelUnavailable("\(reason)")
        @unknown default: throw QAError.modelUnavailable("unknown")
        }
    }

    /// Lightweight intent classifier for the global ask path. Catches the
    /// three classes of "ask the roster, not the LLM" questions:
    ///
    /// - Count: "how many meetings", "number of meetings", "count of meetings"
    /// - List:  "list my meetings", "what meetings do I have", "show all meetings"
    /// - Recent:"most recent meeting", "latest meeting", "last meeting"
    ///
    /// Returns a fully-formed spoken answer when one of these intents fires,
    /// otherwise nil so the orchestrator falls through to retrieval + LLM.
    /// Pure function on `[MeetingHeader]` so it stays trivially testable and
    /// safe to call from `@MainActor`.
    nonisolated static func answerMetadataQuestion(_ question: String, headers: [MeetingHeader]) -> String? {
        let q = question.lowercased()
        let mentionsMeeting = q.contains("meeting")

        let countPatterns = [
            "how many meetings", "how many meeting",
            "number of meetings", "number of meeting",
            "count of meetings", "count of meeting"
        ]
        let listPatterns = ["list", "what meetings", "which meetings", "show all", "show me all", "show my"]
        let recentPatterns = ["recent", "latest", "last"]

        if countPatterns.contains(where: { q.contains($0) }) {
            let n = headers.count
            if n == 0 { return "You have no meetings recorded yet." }
            return "You have \(n) meeting\(n == 1 ? "" : "s") recorded."
        }
        if mentionsMeeting && listPatterns.contains(where: { q.contains($0) }) {
            if headers.isEmpty { return "You have no meetings recorded yet." }
            let titles = headers.prefix(5).map { "\u{2022} \($0.title)" }.joined(separator: "\n")
            return "Your meetings:\n\(titles)"
        }
        if mentionsMeeting && recentPatterns.contains(where: { q.contains($0) }) {
            guard let last = headers.first else { return "You have no meetings yet." }
            return "Your most recent meeting is \"\(last.title)\"."
        }
        return nil
    }

    /// Extracts the counted term from questions like "how many times was AI
    /// mentioned across my meetings?" This intentionally handles only narrow
    /// mention/count phrasing; everything else falls through to retrieval.
    nonisolated static func extractMentionCountTerm(_ question: String) -> String? {
        let lowered = question.lowercased()
        guard lowered.contains("how many"),
              lowered.contains("mention") || lowered.contains("mentioned") else {
            return nil
        }

        if let quoted = firstQuotedPhrase(in: question) {
            return quoted
        }

        let tokens = lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard let mentionIndex = tokens.firstIndex(where: { $0.hasPrefix("mention") }) else {
            return nil
        }

        let stopwords: Set<String> = [
            "a", "across", "all", "an", "are", "be", "been", "can", "count",
            "did", "do", "does", "has", "have", "had", "how", "i", "in",
            "is", "it", "many", "me", "meeting", "meetings", "mention",
            "mentioned", "my", "number", "of", "on", "phrase", "term", "tell",
            "that", "the", "this", "time", "times", "was", "were", "whole",
            "word", "you", "your"
        ]
        return tokens[..<mentionIndex]
            .reversed()
            .first { !stopwords.contains($0) && !$0.isEmpty }
    }

    nonisolated static func answerMentionCount(
        term: String,
        counts: [MeetingMentionCount],
        totalMeetings: Int
    ) -> String {
        let display = term.count <= 3 ? term.uppercased() : term
        let total = counts.reduce(0) { $0 + $1.count }
        let meetingWord = totalMeetings == 1 ? "meeting" : "meetings"
        guard total > 0 else {
            return "I found no whole-word mentions of \(display) across your \(totalMeetings) \(meetingWord)."
        }

        let hitMeetingWord = counts.count == 1 ? "meeting" : "meetings"
        let timeWord = total == 1 ? "time" : "times"
        let strongest = counts
            .sorted {
                if $0.count == $1.count { return $0.title < $1.title }
                return $0.count > $1.count
            }
            .prefix(3)
            .map { "\($0.title) with \($0.count)" }

        var answer = "\(display) was mentioned \(total) \(timeWord) across \(counts.count) \(hitMeetingWord), out of \(totalMeetings) \(meetingWord)."
        if !strongest.isEmpty {
            answer += " The strongest matches were \(naturalList(strongest))."
        }
        return answer
    }

    /// Deterministic answer for broad global-overview questions. In global
    /// chat, a phrase like "what did this meeting talk about?" has no single
    /// selected meeting, so default to the whole library instead of silently
    /// treating the newest meeting as the scope.
    nonisolated static func answerGlobalOverviewQuestion(_ question: String, headers: [MeetingHeader]) -> String? {
        let q = question.lowercased()
        guard q.contains("meeting") else { return nil }
        guard !q.contains("how many"), !q.contains("mention") else { return nil }

        let overviewPatterns = [
            "talk about", "talked about", "talking about",
            "discuss", "discussed", "what kind", "what kinds",
            "what are they about", "what were they about"
        ]
        let asksAboutMeetings = overviewPatterns.contains { q.contains($0) }
            || (q.contains("what") && q.contains("about"))
        guard asksAboutMeetings else { return nil }

        let summarized = headers.filter { $0.summary != nil }
        guard !summarized.isEmpty else { return nil }

        var topicBuckets: [String: (display: String, count: Int)] = [:]
        var decisionSamples: [String] = []
        for header in summarized {
            guard let summary = header.summary else { continue }
            for topic in summary.topics.prefix(8) {
                let key = normalizedTopicKey(topic)
                guard !key.isEmpty else { continue }
                let existing = topicBuckets[key]
                topicBuckets[key] = (existing?.display ?? topic, (existing?.count ?? 0) + 1)
            }
            decisionSamples.append(contentsOf: summary.decisions.prefix(1))
        }

        let topics = topicBuckets.values
            .sorted {
                if $0.count == $1.count { return $0.display < $1.display }
                return $0.count > $1.count
            }
            .prefix(8)
            .map(\.display)
        let themeText: String
        if topics.isEmpty {
            let titles = summarized.prefix(8).map(\.title)
            guard !titles.isEmpty else { return nil }
            themeText = naturalList(titles)
        } else {
            themeText = naturalList(Array(topics))
        }

        let meetingWord = headers.count == 1 ? "meeting" : "meetings"
        var answer = "Across your \(headers.count) \(meetingWord), the main themes are \(themeText)."
        answer += " I found structured summaries for \(summarized.count) of them."
        if let decision = decisionSamples.first, !decision.isEmpty {
            answer += " One recurring concrete item was \(decision)"
            if !answer.hasSuffix(".") { answer += "." }
        }
        return answer
    }

    nonisolated private static func firstQuotedPhrase(in text: String) -> String? {
        let pattern = #""([^"]+)"|'([^']+)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        for index in 1..<match.numberOfRanges {
            let r = match.range(at: index)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { continue }
            let phrase = text[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { return phrase.lowercased() }
        }
        return nil
    }

    nonisolated private static func normalizedTopicKey(_ text: String) -> String {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func naturalList(_ values: [String]) -> String {
        switch values.count {
        case 0:
            return ""
        case 1:
            return values[0]
        case 2:
            return "\(values[0]) and \(values[1])"
        default:
            let head = values.dropLast().joined(separator: ", ")
            return "\(head), and \(values.last ?? "")"
        }
    }

    /// Compact multi-meeting overview block. Each header gets one short
    /// paragraph that lists topics + decisions + action items, capped tight
    /// so even a dozen meetings fit comfortably under our 2400-token budget
    /// alongside the chunk excerpts. Headers without a structured summary
    /// (still-processing or pre-Day 4 records) are skipped silently.
    nonisolated private static func globalOverview(headers: [MeetingHeader]) -> String {
        var blocks: [String] = []
        for h in headers.prefix(Self.globalOverviewHeaderLimit) {
            guard let s = h.summary else { continue }
            var lines: [String] = ["• \(String(h.title.prefix(60)))"]
            if !s.topics.isEmpty {
                lines.append("    Topics: \(s.topics.prefix(5).joined(separator: "; "))")
            }
            if !s.decisions.isEmpty {
                lines.append("    Decisions: \(s.decisions.prefix(4).joined(separator: "; "))")
            }
            if !s.actionItems.isEmpty {
                let items = s.actionItems.prefix(4).map { (desc, owner) -> String in
                    if let owner, !owner.isEmpty { return "\(owner): \(desc)" }
                    return desc
                }
                lines.append("    Actions: \(items.joined(separator: "; "))")
            }
            if !s.openQuestions.isEmpty {
                lines.append("    Open: \(s.openQuestions.prefix(3).joined(separator: "; "))")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Renders the persisted MeetingSummaryRecord as a compact overview block
    /// the LLM can lean on for broad questions ("what did they discuss"). The
    /// summary was generated against the full transcript at ingest time, so it
    /// captures the meeting's gist far better than 8 retrieved chunks ever
    /// could. Costs ~150-400 tokens depending on density; well inside our 2400
    /// context budget.
    nonisolated private static func overview(for meeting: Meeting) -> String? {
        guard let summary = meeting.summary else { return nil }
        var lines: [String] = []
        if !summary.topics.isEmpty {
            lines.append("Topics: \(summary.topics.prefix(10).joined(separator: "; "))")
        }
        if !summary.decisions.isEmpty {
            lines.append("Decisions: \(summary.decisions.prefix(8).joined(separator: "; "))")
        }
        if !summary.actionItems.isEmpty {
            let items = summary.actionItems.prefix(8).map { item -> String in
                if let owner = item.owner, !owner.isEmpty {
                    return "\(owner): \(item.description)"
                }
                return item.description
            }
            lines.append("Action items: \(items.joined(separator: "; "))")
        }
        if !summary.openQuestions.isEmpty {
            lines.append("Open questions: \(summary.openQuestions.prefix(6).joined(separator: "; "))")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
