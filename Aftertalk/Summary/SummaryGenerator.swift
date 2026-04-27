import Foundation
import FoundationModels
import os

protocol LLMService: Sendable {
    func generateSummary(transcript: String) async throws -> (summary: MeetingSummary, latencyMillis: Double)
    func streamSummary(transcript: String) -> AsyncThrowingStream<MeetingSummary.PartiallyGenerated, any Error>
}

enum SummaryError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case generationFailed(String)

    var description: String {
        switch self {
        case .modelUnavailable(let why): "Foundation Models unavailable: \(why)"
        case .generationFailed(let why): "Summary generation failed: \(why)"
        }
    }
}

final class FoundationModelsSummaryGenerator: LLMService, @unchecked Sendable {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Summary")

    /// Foundation Models hard-caps input + output at 4096 tokens. We budget
    /// ~250 system + ~150 prompt scaffolding + ~1200 generation, leaving
    /// roughly 2400 tokens for transcript content. At ~4 chars/token that's
    /// ~9600 chars; we conservatively cap windows at 7500 to absorb the
    /// variance from numerals, hyphens, and speaker labels that tokenize fat.
    /// A 15-min meeting at ~150 wpm produces ~12K chars — guaranteed to need
    /// at least 2 windows.
    private static let maxCharsPerWindow = 7_500

    private static let systemInstructions = """
    You extract structured notes from a meeting transcript.

    Rules:
    - Every field must be grounded in the transcript. Do not invent information.
    - "decisions" are concrete things the meeting agreed on.
    - "actionItems" are commitments. Set "owner" only when a name is explicitly attached in the transcript.
    - "topics" are short noun phrases summarising what was discussed.
    - "openQuestions" are questions raised but not resolved.
    - Be concise. Prefer fewer high-quality items over many vague ones.
    - If the transcript is too short or empty, return empty arrays for all fields.
    """

    private func availability() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw SummaryError.modelUnavailable("\(reason)")
        @unknown default:
            throw SummaryError.modelUnavailable("unknown availability")
        }
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: Self.systemInstructions)
    }

    private func prompt(for transcript: String) -> String {
        """
        Transcript follows. Extract decisions, action items (with owners where attributable), topics, open questions.

        --- TRANSCRIPT ---
        \(transcript)
        --- END ---
        """
    }

    private func partialPrompt(for window: String, index: Int, total: Int) -> String {
        """
        Transcript window \(index + 1) of \(total). Extract only what appears in this window. Do not infer continuity from missing context.

        --- TRANSCRIPT WINDOW \(index + 1)/\(total) ---
        \(window)
        --- END ---
        """
    }

    func generateSummary(transcript: String) async throws -> (summary: MeetingSummary, latencyMillis: Double) {
        try availability()
        let started = ContinuousClock.now
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (.empty, started.duration(to: .now).aftertalkMillis)
        }

        let windows = Self.windows(from: trimmed, maxChars: Self.maxCharsPerWindow)
        do {
            if windows.count <= 1 {
                let response = try await makeSession().respond(
                    to: prompt(for: trimmed),
                    generating: MeetingSummary.self
                )
                return (response.content, started.duration(to: .now).aftertalkMillis)
            }

            log.debug("map-reduce summary across \(windows.count) windows (\(trimmed.count) chars)")
            var partials: [MeetingSummary] = []
            partials.reserveCapacity(windows.count)
            for (i, window) in windows.enumerated() {
                let response = try await makeSession().respond(
                    to: partialPrompt(for: window, index: i, total: windows.count),
                    generating: MeetingSummary.self
                )
                partials.append(response.content)
            }
            let merged = Self.merge(partials)
            return (merged, started.duration(to: .now).aftertalkMillis)
        } catch {
            log.error("summary failed: \(String(describing: error), privacy: .public)")
            throw SummaryError.generationFailed("\(error)")
        }
    }

    func streamSummary(transcript: String) -> AsyncThrowingStream<MeetingSummary.PartiallyGenerated, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try self.availability()
                    let session = self.makeSession()
                    let stream = session.streamResponse(
                        to: self.prompt(for: transcript),
                        generating: MeetingSummary.self
                    )
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Map-reduce helpers

    /// Greedy sentence packer. Walks ChunkIndexer-split sentences and emits
    /// windows whose joined length stays under `maxChars`. Pathological case:
    /// a single sentence longer than `maxChars` becomes its own window — we
    /// accept the over-budget risk rather than mid-sentence-splitting, since
    /// Foundation Models truncates gracefully (just loses tail context) but
    /// hard-fails on malformed input.
    static func windows(from transcript: String, maxChars: Int) -> [String] {
        let sentences = ChunkIndexer.splitSentences(transcript)
        guard !sentences.isEmpty else { return [] }
        var windows: [String] = []
        var current: [String] = []
        var currentChars = 0
        for sentence in sentences {
            let needed = currentChars + sentence.count + (current.isEmpty ? 0 : 1)
            if needed > maxChars && !current.isEmpty {
                windows.append(current.joined(separator: " "))
                current = [sentence]
                currentChars = sentence.count
            } else {
                current.append(sentence)
                currentChars = needed
            }
        }
        if !current.isEmpty { windows.append(current.joined(separator: " ")) }
        return windows
    }

    /// Deterministic merge: dedupe by case-insensitive trimmed text, preserve
    /// first-seen order so the meeting reads chronologically. ActionItem
    /// dedup keys on description; first non-nil owner wins when a later
    /// window names someone we missed. Caps applied to keep the merged
    /// summary scannable on a phone screen — the brief calls for "concise."
    static func merge(_ partials: [MeetingSummary]) -> MeetingSummary {
        guard !partials.isEmpty else { return .empty }
        var decisions = OrderedDedup<String>()
        var topics = OrderedDedup<String>()
        var openQuestions = OrderedDedup<String>()
        var actionsByKey: [String: ActionItem] = [:]
        var actionOrder: [String] = []

        for partial in partials {
            partial.decisions.forEach { decisions.insert(normalize($0)) }
            partial.topics.forEach { topics.insert(normalize($0)) }
            partial.openQuestions.forEach { openQuestions.insert(normalize($0)) }
            for action in partial.actionItems {
                let desc = normalize(action.description)
                guard !desc.isEmpty else { continue }
                let key = desc.lowercased()
                if var existing = actionsByKey[key] {
                    if (existing.owner?.isEmpty ?? true), let owner = action.owner, !owner.isEmpty {
                        existing.owner = owner
                        actionsByKey[key] = existing
                    }
                } else {
                    actionsByKey[key] = ActionItem(description: desc, owner: action.owner)
                    actionOrder.append(key)
                }
            }
        }

        let mergedActions = actionOrder.compactMap { actionsByKey[$0] }.prefix(20)
        return MeetingSummary(
            decisions: Array(decisions.values.prefix(15)),
            actionItems: Array(mergedActions),
            topics: Array(topics.values.prefix(12)),
            openQuestions: Array(openQuestions.values.prefix(10))
        )
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct OrderedDedup<Element: Hashable> {
    private(set) var values: [Element] = []
    private var seen: Set<String> = []

    mutating func insert(_ value: Element) {
        guard let s = value as? String else {
            if !values.contains(where: { $0 == value }) { values.append(value) }
            return
        }
        let key = s.lowercased()
        guard !s.isEmpty, !seen.contains(key) else { return }
        seen.insert(key)
        values.append(value)
    }
}
