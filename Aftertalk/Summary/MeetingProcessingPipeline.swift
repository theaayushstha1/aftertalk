import Foundation
import os

enum ProcessingStage: Equatable, Sendable {
    case idle
    case savingMeeting
    case polishingTranscript
    case chunking
    case embedding(progress: Int, total: Int)
    case summarizing
    case done(meetingId: UUID, summaryLatencyMillis: Double)
    case failed(String)
}

@MainActor
@Observable
final class MeetingProcessingPipeline {
    var stage: ProcessingStage = .idle

    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Pipeline")
    private let repository: MeetingsRepository
    private let embeddings: any EmbeddingService
    private let llm: any LLMService
    private let batchASR: (any BatchASRService)?
    private let chunker = ChunkIndexer()

    init(
        repository: MeetingsRepository,
        embeddings: any EmbeddingService,
        llm: any LLMService,
        batchASR: (any BatchASRService)? = nil
    ) {
        self.repository = repository
        self.embeddings = embeddings
        self.llm = llm
        self.batchASR = batchASR
    }

    func process(
        transcript: String,
        durationSeconds: Double,
        audioFileURL: URL? = nil
    ) async -> UUID? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stage = .failed("empty transcript")
            return nil
        }
        do {
            stage = .savingMeeting
            let initialTitle = Self.suggestedTitle(from: transcript)
            let meetingId = try await repository.createMeeting(
                title: initialTitle,
                transcript: transcript,
                duration: durationSeconds,
                audioFileURL: audioFileURL
            )

            // Streaming Moonshine output is the fallback. If the batch ASR
            // service is wired and we have a WAV to read, run a higher-quality
            // pass and replace the transcript before chunk/embed/summarize.
            // Errors here are non-fatal: graceful degradation is the rule
            // (e.g. dev builds without the model bundled).
            var workingTranscript = transcript
            var workingTitle = initialTitle
            if let batchASR, let audioFileURL {
                stage = .polishingTranscript
                let started = ContinuousClock.now
                do {
                    let polished = try await batchASR.transcribe(audioFile: audioFileURL)
                    let elapsedMs = started.duration(to: .now).aftertalkMillis
                    let polishedText = polished.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !polishedText.isEmpty {
                        workingTranscript = polishedText
                        workingTitle = Self.suggestedTitle(from: polishedText)
                        try await repository.updateTranscript(meetingId: meetingId, transcript: polishedText)
                        if workingTitle != initialTitle {
                            try? await repository.renameMeeting(meetingId, to: workingTitle)
                        }
                        log.info("polished transcript via \(polished.backend, privacy: .public) in \(Int(elapsedMs), privacy: .public) ms")
                    } else {
                        log.warning("batch ASR returned empty text; keeping streaming transcript")
                    }
                } catch let err as BatchASRError {
                    switch err {
                    case .modelMissing(let why):
                        log.warning("batch ASR model missing — falling through: \(why, privacy: .public)")
                    default:
                        log.error("batch ASR failed — falling through: \(String(describing: err), privacy: .public)")
                    }
                } catch {
                    log.error("batch ASR failed — falling through: \(String(describing: error), privacy: .public)")
                }
            }
            let transcript = workingTranscript
            let title = workingTitle

            stage = .chunking
            let drafts = chunker.chunks(from: transcript, durationSeconds: durationSeconds)

            stage = .embedding(progress: 0, total: drafts.count)
            var vectors: [[Float]] = []
            vectors.reserveCapacity(drafts.count)
            for (i, draft) in drafts.enumerated() {
                // Prefix every embedded chunk with meeting + speaker context so
                // cosine similarity rewards "what did Sara say about X" against
                // chunks where Sara was the speaker, and biases cross-meeting
                // recall toward the right meeting topic.
                let embedText = Self.buildEmbedText(meetingTitle: title, draft: draft)
                let v = try await embeddings.embed(embedText)
                vectors.append(v)
                stage = .embedding(progress: i + 1, total: drafts.count)
            }

            try await repository.attachChunks(to: meetingId, drafts: drafts, embeddings: vectors)

            stage = .summarizing
            let started = ContinuousClock.now
            let result = try await llm.generateSummary(transcript: transcript)
            let elapsed = started.duration(to: .now)
            let latency = elapsed.aftertalkMillis
            try await repository.attachSummary(to: meetingId, summary: result.summary, latencyMillis: latency)

            // Meeting-level embedding now uses the structured summary fields
            // (decisions / actions / topics / speakers) instead of the raw
            // transcript head — Layer-1 cross-meeting routing matches on the
            // *gist* of a meeting, not its opening minute.
            let summaryText = Self.buildSummaryEmbedText(title: title, summary: result.summary)
            let summaryEmbedding = try await embeddings.embed(summaryText)
            try await repository.upsertSummaryEmbedding(meetingId: meetingId, embedding: summaryEmbedding)

            stage = .done(meetingId: meetingId, summaryLatencyMillis: latency)
            return meetingId
        } catch {
            log.error("pipeline failed: \(String(describing: error), privacy: .public)")
            stage = .failed("\(error)")
            return nil
        }
    }

    static func suggestedTitle(from transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled meeting" }
        let firstSentence = ChunkIndexer.splitSentences(trimmed).first ?? trimmed
        let clipped = firstSentence.prefix(60)
        let suffix = firstSentence.count > 60 ? "…" : ""
        return String(clipped) + suffix
    }

    static func buildEmbedText(meetingTitle: String, draft: ChunkDraft) -> String {
        let titleSlice = String(meetingTitle.prefix(60))
        if let speaker = draft.speakerName, !speaker.isEmpty {
            return "[Meeting: \(titleSlice)] [Speaker: \(speaker)] \(draft.text)"
        }
        return "[Meeting: \(titleSlice)] \(draft.text)"
    }

    static func buildSummaryEmbedText(title: String, summary: MeetingSummary) -> String {
        var parts: [String] = ["[Meeting: \(String(title.prefix(80)))]"]
        if !summary.topics.isEmpty {
            parts.append("Topics: \(summary.topics.prefix(8).joined(separator: "; "))")
        }
        if !summary.decisions.isEmpty {
            parts.append("Decisions: \(summary.decisions.prefix(6).joined(separator: "; "))")
        }
        let actions = summary.actionItems.prefix(8).map { item in
            if let owner = item.owner, !owner.isEmpty { return "\(owner): \(item.description)" }
            return item.description
        }
        if !actions.isEmpty {
            parts.append("Actions: \(actions.joined(separator: "; "))")
        }
        if !summary.openQuestions.isEmpty {
            parts.append("Open questions: \(summary.openQuestions.prefix(4).joined(separator: "; "))")
        }
        return parts.joined(separator: " ")
    }
}

extension Duration {
    var aftertalkMillis: Double {
        let comps = components
        return Double(comps.seconds) * 1000.0 + Double(comps.attoseconds) / 1e15
    }
}
