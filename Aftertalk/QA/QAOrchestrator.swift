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
    /// Ordered chain of speech tasks. Each call to `speakChained` appends a
    /// Task that awaits the previous tail before invoking the underlying
    /// actor-isolated `tts.speak`. The orchestrator never blocks on
    /// synthesis: the LLM stream keeps draining + the sentence detector
    /// keeps finding boundaries while Kokoro synthesises previous sentences
    /// in the background. Output order is preserved because each Task
    /// awaits its predecessor's `.value` before issuing its own `speak`.
    ///
    /// We track *every* task, not just the tail, so `cancel()` can stop all
    /// of them. A previous version cancelled only the tail — predecessors
    /// kept running their synthesis + enqueue, so a tap on the mic to
    /// interrupt the answer dropped the current player buffer but the next
    /// chunk that finished synthesising one beat later still played, making
    /// the cancel feel unresponsive.
    private var speechTasks: [Task<Void, Never>] = []

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
    - Length: three to five short sentences of plain prose, around 12 to 18 words each. The answer is read aloud sentence by sentence — long run-on sentences sound stilted and break the speech rhythm. No bullet points, no numbered lists, no dashes, no asterisks, no markdown.
    - Speakers are not pre-labeled. Names from the transcript may be misheard — say "the team" or "two people" rather than guessing if you're unsure.
    - Never invent decisions, dates, owners, or meetings that are not in the context.
    - Do not preface with "Based on the meetings" or "According to the context." Just answer.
    - If the overviews and excerpts together don't answer the question, reply with exactly: I don't have that across your meetings yet.
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
    /// `.voiceChat` (TTS) back to `.measurement` (clean ASR).
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

    /// Flip the audio session from clean-listening (`.measurement`) to
    /// voice-chat with AEC. Called the moment we're about to speak so the
    /// user heard a clean mic during the question and gets AEC during the
    /// answer (so barge-in can ignore Kokoro's playback bleed).
    private func enterSpeakingSession() async {
        do {
            try await AudioSessionManager.shared.configureForVoiceChat()
        } catch {
            log.warning("session flip to voiceChat failed: \(String(describing: error), privacy: .public) — continuing with current mode")
        }
    }

    /// Append `sentence` to the ordered speech chain and return immediately.
    /// The caller (LLM stream loop) keeps reading the next snapshot while
    /// Kokoro synthesises this sentence in the background. See `speakTail`.
    private func speakChained(_ sentence: String) {
        let prev = speechTasks.last
        let svc = tts
        let task = Task { [prev] in
            if let prev { _ = await prev.value }
            if Task.isCancelled { return }
            await svc.speak(sentence)
        }
        speechTasks.append(task)
    }

    /// Wait for every queued sentence in the chain to finish synthesising +
    /// being scheduled on the player. Used by the orchestrator after the LLM
    /// stream completes so we don't tear down `liveAnswer` mid-playback.
    private func awaitSpeakChain() async {
        let tasks = speechTasks
        speechTasks.removeAll()
        for t in tasks { _ = await t.value }
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
            speakChained(sentence)
        }
        await awaitSpeakChain()
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
                    let preview = sentence.prefix(48)
                    log.info("speak[\(spokenCount + 1, privacy: .public)/\(self.maxSpokenSentences, privacy: .public)] chain: \(preview, privacy: .public)")
                    speakChained(sentence)
                    spokenCount += 1
                    if ttfswMillis == nil, let start = ttfswStart {
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
                    let preview = sentence.prefix(48)
                    log.info("speak[trailing] chain: \(preview, privacy: .public)")
                    if !sentence.isEmpty, stage != .speaking {
                        stage = .speaking
                        await enterSpeakingSession()
                        armBargeIn()
                    }
                    speakChained(sentence)
                    spokenCount += 1
                    // Some answers complete before the streaming detector
                    // sees a sentence-final punctuation token — the FIRST
                    // sentence then arrives only via this `finalize` path.
                    // Without setting `ttfswMillis` here the metric stays
                    // nil and we silently report "no TTFSW" for those turns.
                    if ttfswMillis == nil, let start = ttfswStart {
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
        await awaitSpeakChain()
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
                    speakChained(sentence)
                    spokenCount += 1
                    if ttfswMillis == nil, let start = ttfswStart {
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
                    speakChained(sentence)
                    spokenCount += 1
                    if ttfswMillis == nil, let start = ttfswStart {
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

        await awaitSpeakChain()
        bargeIn.stop()

        let elapsed = totalStart.duration(to: .now).aftertalkMillis
        liveAnswer = ""
        stage = .idle
        return QAResult(
            question: question,
            answer: lastSnapshot,
            citations: [],  // no chunk-level retrieval hits in this path
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

        // Metadata router: trivial questions about the meeting roster ("how
        // many meetings", "list my meetings", "most recent meeting") never
        // match in chunk-embedding space — the gate below fires and we'd say
        // "I don't have that across your meetings yet" even though we
        // trivially do. Intercept those before retrieval and answer from the
        // SwiftData header roster directly. Non-metadata questions fall
        // through unchanged so the grounding gate still protects everything
        // else.
        do {
            let allHeaders = try await repository.allMeetingHeaders()
            if let metaAnswer = Self.answerMetadataQuestion(trimmed, headers: allHeaders) {
                log.info("global metadata router hit: q=\"\(trimmed.prefix(40), privacy: .public)\" meetings=\(allHeaders.count, privacy: .public)")
                stage = .speaking
                liveAnswer = metaAnswer
                await enterSpeakingSession()
                armBargeIn()
                await tts.speak(metaAnswer)
                bargeIn.stop()
                let elapsed = totalStart.duration(to: .now).aftertalkMillis
                liveAnswer = ""
                stage = .idle
                return QAResult(
                    question: trimmed,
                    answer: metaAnswer,
                    citations: [],
                    groundedByLLM: false,
                    ttfswMillis: nil,
                    totalMillis: elapsed
                )
            }
        } catch {
            log.warning("metadata router header fetch failed: \(String(describing: error), privacy: .public) — falling through to retrieval")
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
        let baselineHeaders = Array(allHeadersForOverview.prefix(5))
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
        let excerptsSection: String
        if renderedLines.isEmpty {
            // Retrieval missed but we have summaries. Tell the LLM
            // explicitly so it doesn't hallucinate excerpts that aren't
            // there — answer from the overview block alone or refuse
            // honestly.
            excerptsSection = "No specific excerpts retrieved. Answer from the overviews above; if they don't contain the answer, refuse honestly per your instructions.\n"
        } else {
            excerptsSection = "Excerpts (sorted by relevance, across multiple meetings):\n\n\(renderedLines.joined(separator: "\n\n"))"
        }
        let prompt = """
        Question: \(trimmed)

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
                    speakChained(sentence)
                    spokenCount += 1
                    if ttfswMillis == nil, let start = ttfswStart {
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
                    speakChained(sentence)
                    spokenCount += 1
                    // Mirror of the per-meeting fix: cover the case where
                    // the first speakable sentence only emerges via the
                    // trailing finalize path. Without this, TTFSW silently
                    // reports nil for short / fast answers.
                    if ttfswMillis == nil, let start = ttfswStart {
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

        await awaitSpeakChain()
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

    private func checkAvailability() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return
        case .unavailable(let reason): throw QAError.modelUnavailable("\(reason)")
        @unknown default: throw QAError.modelUnavailable("unknown")
        }
    }

    /// Lightweight intent classifier for the global ask path. Catches the
    /// three classes of "ask the database, not the LLM" questions:
    ///
    /// - Count: "how many meetings", "number of meetings", "count of meetings"
    /// - List:  "list my meetings", "what meetings do I have", "show all meetings"
    /// - Recent:"most recent meeting", "latest meeting", "last meeting"
    ///
    /// Returns a fully-formed spoken answer when one of these intents fires,
    /// otherwise nil so the orchestrator falls through to retrieval + LLM.
    /// Pure function on `[MeetingHeader]` so it stays trivially testable and
    /// safe to call from `@MainActor`.
    static func answerMetadataQuestion(_ question: String, headers: [MeetingHeader]) -> String? {
        let q = question.lowercased()
        guard q.contains("meeting") else { return nil }

        let countPatterns = ["how many", "number of", "count"]
        let listPatterns = ["list", "what meetings", "which meetings", "show all", "show me all", "show my"]
        let recentPatterns = ["recent", "latest", "last"]

        if countPatterns.contains(where: { q.contains($0) }) {
            let n = headers.count
            if n == 0 { return "You have no meetings recorded yet." }
            return "You have \(n) meeting\(n == 1 ? "" : "s") recorded."
        }
        if listPatterns.contains(where: { q.contains($0) }) {
            if headers.isEmpty { return "You have no meetings recorded yet." }
            let titles = headers.prefix(5).map { "\u{2022} \($0.title)" }.joined(separator: "\n")
            return "Your meetings:\n\(titles)"
        }
        if recentPatterns.contains(where: { q.contains($0) }) {
            guard let last = headers.first else { return "You have no meetings yet." }
            return "Your most recent meeting is \"\(last.title)\"."
        }
        return nil
    }

    /// Compact multi-meeting overview block. Each header gets one short
    /// paragraph that lists topics + decisions + action items, capped tight
    /// so even five meetings fit comfortably under our 2400-token budget
    /// alongside the chunk excerpts. Headers without a structured summary
    /// (still-processing or pre-Day 4 records) are skipped silently.
    private static func globalOverview(headers: [MeetingHeader]) -> String {
        var blocks: [String] = []
        for h in headers.prefix(5) {
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
    private static func overview(for meeting: Meeting) -> String? {
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
