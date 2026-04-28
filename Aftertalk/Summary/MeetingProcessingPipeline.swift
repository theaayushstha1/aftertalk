import Foundation
import os

enum ProcessingStage: Equatable, Sendable {
    case idle
    case savingMeeting
    case polishingTranscript
    case diarizing
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
    private let diarization: (any DiarizationService)?
    private let chunker = ChunkIndexer()

    init(
        repository: MeetingsRepository,
        embeddings: any EmbeddingService,
        llm: any LLMService,
        batchASR: (any BatchASRService)? = nil,
        diarization: (any DiarizationService)? = nil
    ) {
        self.repository = repository
        self.embeddings = embeddings
        self.llm = llm
        self.batchASR = batchASR
        self.diarization = diarization
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
            // Diarization runs in parallel with polish (both read the WAV but
            // their CoreML models live in separate ANE/GPU partitions, so we
            // get the wallclock saving for free). Errors on either branch are
            // non-fatal: graceful degradation is the rule (e.g. dev builds
            // without the model bundled).
            var workingTranscript = transcript
            var workingTitle = initialTitle
            var canonical: CanonicalTranscript? = nil
            var speakerSegments: [SpeakerSegment] = []

            if audioFileURL != nil, batchASR != nil || diarization != nil {
                // Surface "polishing" first since it's almost always the
                // longer of the two. We update to .diarizing only if polish
                // returns first and diarization is still running.
                stage = (batchASR != nil) ? .polishingTranscript : .diarizing
            }

            if let audioFileURL {
                async let polishedResult: CanonicalTranscript? = {
                    guard let batchASR else { return nil }
                    let started = ContinuousClock.now
                    do {
                        let polished = try await batchASR.transcribe(audioFile: audioFileURL)
                        let elapsedMs = started.duration(to: .now).aftertalkMillis
                        log.info("polished transcript via \(polished.backend, privacy: .public) in \(Int(elapsedMs), privacy: .public) ms")
                        return polished
                    } catch let err as BatchASRError {
                        switch err {
                        case .modelMissing(let why):
                            log.warning("batch ASR model missing — falling through: \(why, privacy: .public)")
                        default:
                            log.error("batch ASR failed — falling through: \(String(describing: err), privacy: .public)")
                        }
                        return nil
                    } catch {
                        log.error("batch ASR failed — falling through: \(String(describing: error), privacy: .public)")
                        return nil
                    }
                }()

                async let diarResult: [SpeakerSegment] = {
                    guard let diarization else { return [] }
                    let started = ContinuousClock.now
                    do {
                        let segments = try await diarization.diarize(audioFile: audioFileURL)
                        let elapsedMs = started.duration(to: .now).aftertalkMillis
                        log.info("diarized in \(Int(elapsedMs), privacy: .public) ms — \(segments.count, privacy: .public) segments")
                        return segments
                    } catch let err as DiarizationError {
                        switch err {
                        case .modelMissing(let why):
                            log.warning("diarization model missing — falling through: \(why, privacy: .public)")
                        default:
                            log.error("diarization failed — falling through: \(String(describing: err), privacy: .public)")
                        }
                        return []
                    } catch {
                        log.error("diarization failed — falling through: \(String(describing: error), privacy: .public)")
                        return []
                    }
                }()

                canonical = await polishedResult
                speakerSegments = await diarResult

                if let polished = canonical {
                    let polishedText = polished.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !polishedText.isEmpty {
                        workingTranscript = polishedText
                        workingTitle = Self.suggestedTitle(from: polishedText)
                        try await repository.updateTranscript(meetingId: meetingId, transcript: polishedText)
                        if workingTitle != initialTitle {
                            try? await repository.renameMeeting(meetingId, to: workingTitle)
                        }
                    } else {
                        log.warning("batch ASR returned empty text; keeping streaming transcript")
                    }
                }

                // Persist the speaker roster up front so the UI can show
                // labels even if the chunking stage downstream fails.
                if !speakerSegments.isEmpty {
                    let drafts = DiarizationReconciler.buildSpeakerRoster(from: speakerSegments)
                    try? await repository.attachSpeakers(to: meetingId, drafts: drafts)
                }
            }
            let transcript = workingTranscript
            let title = workingTitle

            stage = .chunking
            // Reconcile diarization segments with Parakeet word timings so
            // each chunk we emit gets a dominant speakerId. When we don't
            // have polished word timings (Moonshine fall-through), diarize
            // chunks by sentence-start time only.
            let wordAssignments: [WordSpeakerAssignment]
            if let canonical, !speakerSegments.isEmpty {
                wordAssignments = DiarizationReconciler.assignWords(
                    words: canonical.words,
                    segments: speakerSegments
                )
            } else {
                wordAssignments = []
            }
            var drafts = chunker.chunks(from: transcript, durationSeconds: durationSeconds)
            if !wordAssignments.isEmpty {
                drafts = chunker.stampSpeakers(on: drafts, words: wordAssignments)
            } else if !speakerSegments.isEmpty {
                // No word timings (Moonshine path) but diarization ran: fall
                // back to picking the speaker whose segment overlaps the
                // chunk's [startSec, endSec] window the most.
                drafts = drafts.map { d in
                    var overlap: [String: Double] = [:]
                    for seg in speakerSegments {
                        let ov = max(0, min(seg.endSec, d.endSec) - max(seg.startSec, d.startSec))
                        if ov > 0 { overlap[seg.speakerId, default: 0] += ov }
                    }
                    let sid = overlap.max(by: { $0.value < $1.value })?.key
                    return ChunkDraft(
                        orderIndex: d.orderIndex,
                        text: d.text,
                        startSec: d.startSec,
                        endSec: d.endSec,
                        speakerName: d.speakerName,
                        speakerId: sid
                    )
                }
            }

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
