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
            var rosterByspeakerId: [String: String] = [:]

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

                // Drop ~725 MB of resident model weights (Parakeet ASR + Pyannote
                // diarization) before chunk/embed/summarize. Neither service is
                // touched again — RAG + Foundation Models do all downstream work
                // and Q&A only needs the streaming Moonshine handle. Without this
                // the foreground app sits at ~1.6 GB across a 30-min meeting and
                // jetsam terminates us mid-Q&A on iPhone Air.
                if batchASR != nil { await batchASR?.cleanup() }
                if diarization != nil { await diarization?.cleanup() }

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
                    rosterByspeakerId = Dictionary(
                        uniqueKeysWithValues: drafts.map { ($0.speakerId, $0.displayName) }
                    )
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

            // Resolve each chunk's display name from the roster so retrieval
            // (ContextPacker reads `chunk.speakerName`) and the embed prefix
            // get a human-readable label, not the raw "Speaker_1" id.
            if !rosterByspeakerId.isEmpty {
                drafts = drafts.map { d in
                    let resolvedName = d.speakerId.flatMap { rosterByspeakerId[$0] } ?? d.speakerName
                    return ChunkDraft(
                        orderIndex: d.orderIndex,
                        text: d.text,
                        startSec: d.startSec,
                        endSec: d.endSec,
                        speakerName: resolvedName,
                        speakerId: d.speakerId
                    )
                }
            }

            // Build a speaker-attributed transcript when we have word-level
            // assignments + a roster, so the summary LLM can attach owners
            // to action items. Falls through to plain transcript otherwise.
            let summaryTranscript = Self.attributedTranscript(
                fallback: transcript,
                words: wordAssignments,
                roster: rosterByspeakerId
            )

            // Foundation Models summary + chunk embedding share no data, so we
            // run them concurrently. Foundation Models is ANE-bound (~30 tok/s,
            // ~400 output tokens ≈ 13 s pure model time + first-token overhead);
            // gte-small is GPU-bound and processes a 30-min meeting's chunks in
            // ~2-3 s. Running them serially the user waits ~17 s + ~3 s; running
            // in parallel they wait ≈ max of the two. Net: 2-3 s shaved off the
            // post-recording stall, no quality cost.
            async let summaryResult = llm.generateSummary(transcript: summaryTranscript)

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
            let result = try await summaryResult
            // `result.latencyMillis` is the LLM's own measured wallclock — the
            // honest perf number for the badge, even though we ran it concurrent
            // with embedding above.
            let latency = result.latencyMillis
            try await repository.attachSummary(to: meetingId, summary: result.summary, latencyMillis: latency)

            // Promote the LLM's structured topics into a real title. Until now
            // `workingTitle` was a transcript fragment (literally the first 60
            // chars of speech), which produced gems like "Wonderful," and "Of
            // the physical, the common sense, the a" in the meeting list. The
            // summary's `topics` field is already 2-4 short noun phrases ranked
            // by prominence — exactly what a human title would be. Skip the
            // upgrade if the user manually renamed before summary landed (rare
            // but possible on long meetings with fast taps).
            let topicTitle = Self.title(fromTopics: result.summary.topics)
            if let topicTitle, topicTitle != workingTitle {
                try? await repository.renameMeeting(meetingId, to: topicTitle)
                workingTitle = topicTitle
            }

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

    /// Build a meeting title from the LLM's ranked topic phrases. Joins up to
    /// the top two topics with " · " so a meeting that genuinely covered two
    /// distinct things ("Pricing tiers · Q3 hiring") reads naturally; a
    /// single-topic meeting just shows that topic. Returns nil when topics is
    /// empty so callers can keep the fallback fragment.
    static func title(fromTopics topics: [String]) -> String? {
        let cleaned = topics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let top = Array(cleaned.prefix(2))
        let joined = top.joined(separator: " · ")
        // Hard cap so a verbose topic phrase doesn't blow the list row width.
        let clipped = joined.prefix(64)
        return clipped.count < joined.count ? String(clipped) + "…" : String(clipped)
    }

    static func suggestedTitle(from transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled meeting" }
        let firstSentence = ChunkIndexer.splitSentences(trimmed).first ?? trimmed
        let clipped = firstSentence.prefix(60)
        let suffix = firstSentence.count > 60 ? "…" : ""
        return String(clipped) + suffix
    }

    /// Render the transcript with `Speaker N:` prefixes when we have word-level
    /// speaker assignments + a roster mapping ids → display names. Consecutive
    /// words by the same speaker are folded into one utterance line. When no
    /// diarization data is present, falls back to the plain transcript so the
    /// summary call is unaffected on the Moonshine-only path.
    static func attributedTranscript(
        fallback: String,
        words: [WordSpeakerAssignment],
        roster: [String: String]
    ) -> String {
        guard !words.isEmpty, !roster.isEmpty else { return fallback }
        var lines: [String] = []
        var currentSid: String? = nil
        var buffer: [String] = []
        for w in words {
            if w.speakerId != currentSid {
                if !buffer.isEmpty {
                    let label = currentSid.flatMap { roster[$0] } ?? "Unknown speaker"
                    lines.append("\(label): \(buffer.joined(separator: " "))")
                    buffer.removeAll(keepingCapacity: true)
                }
                currentSid = w.speakerId
            }
            buffer.append(w.text)
        }
        if !buffer.isEmpty {
            let label = currentSid.flatMap { roster[$0] } ?? "Unknown speaker"
            lines.append("\(label): \(buffer.joined(separator: " "))")
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? fallback : joined
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
