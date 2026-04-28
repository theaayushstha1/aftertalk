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
    /// "you interrupted, hold to ask again" hint without us re-arming ASR
    /// automatically (auto-restart is the next iteration of Session A).
    var didBargeIn: Bool = false
    /// Tail of an ordered chain of speech tasks. Each call to `speakChained`
    /// appends a Task that awaits the previous tail before invoking the
    /// underlying actor-isolated `tts.speak`. The orchestrator never blocks on
    /// synthesis: the LLM stream keeps draining + the sentence detector keeps
    /// finding boundaries while Kokoro synthesises previous sentences in the
    /// background. Output order is preserved because each Task awaits its
    /// predecessor's `.value` before issuing its own `speak`. TTSWorker's FIFO
    /// `scheduleBuffer` queue then plays them gaplessly — sentence N+1's PCM
    /// is already on the player by the time N's tail finishes, so AVPlayerNode
    /// never starves and never re-attacks.
    private var speakTail: Task<Void, Never>?

    /// Cosine similarity floor below which we treat the question as off-topic
    /// and refuse to call the LLM (CS Navigator grounding-gate pattern). 0.4
    /// was the original guess; in real Day-4 testing on iPhone 17 Pro Max
    /// against the golden 5-min meeting, on-topic questions consistently
    /// scored 0.28–0.45 with NLContextualEmbedding (gte-small produces tighter
    /// scores). 0.4 was rejecting real questions and producing the "single
    /// disclaimer sentence and stop" symptom. Lowered to 0.22 — well below
    /// every legitimate match observed and still safely above noise.
    private let groundingThreshold: Float = 0.22

    /// Hard cap on spoken sentences. The brief asks for ~3-5 sentence answers,
    /// but soft-wraps + commas can split a single thought into multiple emitted
    /// "sentences" so we leave headroom.
    private let maxSpokenSentences: Int = 10

    private static let globalSystemInstructions = """
    You are a meeting assistant answering a question across multiple recorded meetings on the user's phone. Each excerpt is tagged with its source meeting title and timestamp. Your answer is read aloud, so write it the way a person would speak it — natural, conversational, in your own words.

    How to answer:
    - Synthesize across meetings. If the same person committed to similar things in different meetings, fold them into one coherent statement and name the meetings briefly ("in the standup and the planning sync, ...").
    - When a fact comes from a single meeting, you can mention it casually ("in the planning sync") but don't quote the title verbatim if it's awkward.
    - Use the "Meeting overviews" block as the trusted backbone — it lists each meeting's topics, decisions, action items. Use the "Excerpts" for specifics and grounding.
    - Length: three to five sentences of plain prose. No bullet points, no numbered lists, no dashes, no asterisks, no markdown.
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
    - Length: three to five sentences of plain prose. No bullet points, no numbered lists, no dashes, no asterisks, no markdown, no headings, no code blocks. Sentences with periods only.
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
        // Drop the speech chain too — otherwise sentences from the cancelled
        // ask keep landing in the worker after we've cleared the player.
        speakTail?.cancel()
        speakTail = nil
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
    private func armBargeIn() {
        bargeIn.start { [weak self] in
            guard let self else { return }
            self.didBargeIn = true
            self.log.info("user barged in — cancelling answer playback")
            Task { await self.cancel() }
        }
    }

    /// Append `sentence` to the ordered speech chain and return immediately.
    /// The caller (LLM stream loop) keeps reading the next snapshot while
    /// Kokoro synthesises this sentence in the background. See `speakTail`.
    private func speakChained(_ sentence: String) {
        let prev = speakTail
        let svc = tts
        speakTail = Task { [prev] in
            if let prev { _ = await prev.value }
            if Task.isCancelled { return }
            await svc.speak(sentence)
        }
    }

    /// Wait for every queued sentence in the chain to finish synthesising +
    /// being scheduled on the player. Used by the orchestrator after the LLM
    /// stream completes so we don't tear down `liveAnswer` mid-playback.
    private func awaitSpeakChain() async {
        let tail = speakTail
        speakTail = nil
        if let tail { _ = await tail.value }
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
        for sentence in sentences {
            if Task.isCancelled { break }
            speakChained(sentence)
        }
        await awaitSpeakChain()
        stage = .idle
    }

    func ask(question: String, in meeting: Meeting) async -> QAResult? {
        await cancel()
        let task = Task<QAResult?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.runAsk(question: question, in: meeting)
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
    func askGlobal(question: String, repository: MeetingsRepository) async -> QAResult? {
        await cancel()
        let task = Task<QAResult?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.runAskGlobal(question: question, repository: repository)
        }
        inFlight = task
        return await task.value
    }

    private func runAsk(question: String, in meeting: Meeting) async -> QAResult? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        stage = .retrieving
        liveAnswer = ""
        didBargeIn = false
        let totalStart = ContinuousClock.now

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

        // Grounding gate. If nothing meaningful came back, skip the LLM and
        // speak a fixed disclaimer. Cheaper, faster, no hallucination risk.
        if retrieval.isEmpty || retrieval.topScore < groundingThreshold {
            log.warning("grounding gate fired (topScore=\(retrieval.topScore, privacy: .public) < \(self.groundingThreshold, privacy: .public)) — speaking disclaimer instead of running LLM")
            let disclaimer = "I don't have that in the meeting transcripts."
            stage = .speaking
            liveAnswer = disclaimer
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
        var ttfswStart: ContinuousClock.Instant?
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
                    // TTFSW now measures "first sentence handed to the synth
                    // chain" — the user perceives this as the moment the voice
                    // starts because Kokoro's first audio chunk lands ~300 ms
                    // later regardless. This is also when the speaker icon
                    // animates in the UI.
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
                    speakChained(sentence)
                    spokenCount += 1
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

    private func runAskGlobal(question: String, repository: MeetingsRepository) async -> QAResult? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        stage = .retrieving
        liveAnswer = ""
        didBargeIn = false
        let totalStart = ContinuousClock.now

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

        if retrieval.isEmpty || retrieval.topScore < groundingThreshold {
            log.warning("global grounding gate fired (topScore=\(retrieval.topScore, privacy: .public))")
            let disclaimer = "I don't have that across your meetings yet."
            stage = .speaking
            liveAnswer = disclaimer
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
        let headers: [MeetingHeader]
        do {
            headers = try await repository.meetingHeaders(for: citedMeetingIds)
        } catch {
            log.error("header fetch failed: \(String(describing: error), privacy: .public)")
            stage = .failed("headers: \(error)")
            return nil
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
        let prompt = """
        Question: \(trimmed)

        \(overviewSection)Excerpts (sorted by relevance, across multiple meetings):

        \(renderedLines.joined(separator: "\n\n"))
        """

        stage = .generating
        var detector = SentenceBoundaryDetector()
        var lastSnapshot = ""
        var ttfswStart: ContinuousClock.Instant?
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
                    speakChained(sentence)
                    spokenCount += 1
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
