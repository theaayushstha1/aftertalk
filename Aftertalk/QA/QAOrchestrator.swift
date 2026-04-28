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
    private var inFlight: Task<QAResult?, Never>?

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
        await tts.stop()
        liveAnswer = ""
        stage = .idle
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
            await tts.speak(sentence)
        }
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

    private func runAsk(question: String, in meeting: Meeting) async -> QAResult? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        stage = .retrieving
        liveAnswer = ""
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
            await tts.speak(disclaimer)
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
                }
                for sentence in sentences {
                    if Task.isCancelled { break outer }
                    // Cap the spoken voice but let the model keep streaming
                    // text — the chat bubble shows the full answer even after
                    // the speaker goes quiet.
                    if spokenCount >= maxSpokenSentences { break }
                    let preview = sentence.prefix(48)
                    log.info("speak[\(spokenCount + 1, privacy: .public)/\(self.maxSpokenSentences, privacy: .public)] enqueue: \(preview, privacy: .public)")
                    await tts.speak(sentence)
                    log.info("speak[\(spokenCount + 1, privacy: .public)] returned (synth done, queued for playback)")
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
                    log.info("speak[trailing] enqueue: \(preview, privacy: .public)")
                    await tts.speak(sentence)
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

    private func checkAvailability() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return
        case .unavailable(let reason): throw QAError.modelUnavailable("\(reason)")
        @unknown default: throw QAError.modelUnavailable("unknown")
        }
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
