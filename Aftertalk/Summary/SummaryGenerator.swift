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
    fileprivate static let staticLog = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Summary")

    /// Foundation Models hard-caps input + output at 4096 tokens. We budget
    /// ~250 system + ~150 prompt scaffolding + ~1200 generation, leaving
    /// roughly 2400 tokens for transcript content. At ~4 chars/token that's
    /// ~9600 chars; we conservatively cap windows at 3500 to absorb ASR
    /// punctuation drift and tokenize-fat numerals/hyphens/speaker labels.
    /// Tighter cap = more partials, but each is safely under context, which
    /// matters on 45+ minute recordings where merged outputs would otherwise
    /// re-blow the window during reduce.
    private static let maxCharsPerWindow = 3_500

    /// Hard ceiling for any single sentence fed into the greedy packer.
    /// Moonshine ASR sometimes emits multi-thousand-char "sentences" with
    /// missing terminal punctuation; without this split they bypass the
    /// packer's window cap entirely.
    private static let maxCharsPerSentence = 1_000

    private static let systemInstructions = """
    You extract structured notes from a meeting transcript.

    Rules:
    - Every field must be grounded in the transcript. Do not invent information.
    - "decisions" are concrete things the meeting agreed on.
    - "actionItems" are commitments. Set "owner" only when a name is explicitly attached in the transcript.
    - "topics" are short noun phrases summarising what was discussed.
    - "openQuestions" are questions raised but not resolved during the meeting.
    - Be concise. Prefer fewer high-quality items over many vague ones.
    - If the transcript is too short or empty, return empty arrays for all fields.

    Speaker attribution:
    - The transcript may be prefixed with speaker labels at the start of each line (for example `Speaker 1: ...`, `Speaker 2: ...`).
    - When a decision or action is attributed to such a speaker label and no proper name is mentioned in the line, set "owner" to that speaker label verbatim ("Speaker 1", "Speaker 2", etc.).
    - If a proper name is mentioned alongside the speaker label, prefer the proper name.
    """

    /// Owner strings the LLM emits when it should have omitted the field.
    /// All compared post-trim, post-lowercase.
    private static let ownerSentinels: Set<String> = [
        "nil", "null", "none", "unknown", "unspecified", "n/a", "n.a", "tbd",
        "-", "—", "_", "?"
    ]

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

        if windows.count <= 1 {
            do {
                let summary = try await streamCollect(prompt: prompt(for: trimmed))
                return (summary, started.duration(to: .now).aftertalkMillis)
            } catch {
                logTyped(error, label: "single-window")
                throw SummaryError.generationFailed("\(error)")
            }
        }

        log.debug("map-reduce summary across \(windows.count) windows (\(trimmed.count) chars)")
        var partials: [MeetingSummary] = []
        partials.reserveCapacity(windows.count)
        var lastError: (any Error)?

        for (i, window) in windows.enumerated() {
            do {
                let summary = try await summarizeWindowWithSplit(
                    window: window,
                    index: i,
                    total: windows.count,
                    depth: 0
                )
                partials.append(summary)
            } catch {
                lastError = error
                logTyped(error, label: "window \(i + 1)/\(windows.count)")
                continue
            }
        }

        if !partials.isEmpty {
            return (Self.reduce(partials), started.duration(to: .now).aftertalkMillis)
        }

        // Every window failed; last-ditch single shot on the whole transcript.
        do {
            let summary = try await streamCollect(prompt: prompt(for: trimmed))
            return (summary, started.duration(to: .now).aftertalkMillis)
        } catch {
            logTyped(error, label: "fallback single-shot")
            throw SummaryError.generationFailed("\(lastError ?? error)")
        }
    }

    /// Try a window once. On `exceededContextWindowSize`, split in half on a
    /// sentence boundary and recurse, capped at depth 3 so we never blow the
    /// stack on a degenerate transcript.
    private func summarizeWindowWithSplit(
        window: String,
        index: Int,
        total: Int,
        depth: Int
    ) async throws -> MeetingSummary {
        let safe = await Self.tokenBudgetSafe(window, instructions: Self.systemInstructions)
        if !safe, depth < 3 {
            let halves = Self.splitWindowInHalf(window)
            if halves.count == 2 {
                let left = try await summarizeWindowWithSplit(
                    window: halves[0], index: index, total: total, depth: depth + 1
                )
                let right = try await summarizeWindowWithSplit(
                    window: halves[1], index: index, total: total, depth: depth + 1
                )
                return Self.merge([left, right])
            }
        }

        do {
            return try await streamCollect(
                prompt: partialPrompt(for: window, index: index, total: total)
            )
        } catch let err as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = err, depth < 3 {
                let halves = Self.splitWindowInHalf(window)
                if halves.count == 2 {
                    let left = try await summarizeWindowWithSplit(
                        window: halves[0], index: index, total: total, depth: depth + 1
                    )
                    let right = try await summarizeWindowWithSplit(
                        window: halves[1], index: index, total: total, depth: depth + 1
                    )
                    return Self.merge([left, right])
                }
            }
            throw err
        }
    }

    /// Stream a generation and materialize the last partial snapshot, even
    /// if the stream throws midway. Decoding failures past the first valid
    /// snapshot still yield a usable (if shorter) summary.
    private func streamCollect(prompt: String) async throws -> MeetingSummary {
        let session = makeSession()
        let stream = session.streamResponse(to: prompt, generating: MeetingSummary.self)
        var last: MeetingSummary.PartiallyGenerated?
        do {
            for try await snapshot in stream {
                last = snapshot.content
            }
        } catch {
            if let last { return Self.materialize(last) }
            throw error
        }
        guard let last else {
            return .empty
        }
        return Self.materialize(last)
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

    private func logTyped(_ error: any Error, label: String) {
        if let err = error as? LanguageModelSession.GenerationError {
            switch err {
            case .exceededContextWindowSize(let ctx):
                log.error("\(label, privacy: .public) exceededContextWindowSize: \(ctx.debugDescription, privacy: .public)")
            case .decodingFailure(let ctx):
                log.error("\(label, privacy: .public) decodingFailure: \(ctx.debugDescription, privacy: .public)")
            default:
                log.error("\(label, privacy: .public) generation error: \(String(describing: err), privacy: .public)")
            }
        } else {
            log.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Map-reduce helpers

    /// Greedy sentence packer. Sentences are first hard-split so none exceed
    /// `maxCharsPerSentence`; the packer then walks them, emitting windows
    /// whose joined length stays under `maxChars`. With the pre-split, the
    /// pathological "single oversized sentence becomes its own window" case
    /// can no longer occur.
    static func windows(from transcript: String, maxChars: Int) -> [String] {
        let raw = ChunkIndexer.splitSentences(transcript)
        let sentences = hardSplitLongSentences(raw, maxChars: maxCharsPerSentence)
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

    /// Split sentences longer than `maxChars` on `,`, `;`, `:` clause
    /// boundaries; if the sentence has none, falls back to fixed-char chunks.
    /// Output sentences are all <= roughly `maxChars` (the boundary scan
    /// keeps clauses intact so a single clause may slightly exceed the limit
    /// before the fixed-char fallback kicks in).
    static func hardSplitLongSentences(_ sentences: [String], maxChars: Int) -> [String] {
        guard maxChars > 0 else { return sentences }
        var out: [String] = []
        out.reserveCapacity(sentences.count)
        for sentence in sentences {
            if sentence.count <= maxChars {
                out.append(sentence)
                continue
            }
            out.append(contentsOf: splitOnClauseBoundaries(sentence, maxChars: maxChars))
        }
        return out
    }

    private static func splitOnClauseBoundaries(_ sentence: String, maxChars: Int) -> [String] {
        let clauseChars: Set<Character> = [",", ";", ":"]
        var pieces: [String] = []
        var buffer = ""
        for ch in sentence {
            buffer.append(ch)
            if clauseChars.contains(ch), buffer.count >= maxChars {
                pieces.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            pieces.append(buffer.trimmingCharacters(in: .whitespaces))
        }
        // If clause-splitting failed to bring pieces under `maxChars`, hard-split
        // those individual pieces by character count.
        var final: [String] = []
        final.reserveCapacity(pieces.count)
        for piece in pieces {
            if piece.count <= maxChars {
                final.append(piece)
            } else {
                final.append(contentsOf: fixedCharSplit(piece, maxChars: maxChars))
            }
        }
        return final.filter { !$0.isEmpty }
    }

    private static func fixedCharSplit(_ s: String, maxChars: Int) -> [String] {
        guard maxChars > 0, !s.isEmpty else { return [s].filter { !$0.isEmpty } }
        var out: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: maxChars, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[idx..<end]))
            idx = end
        }
        return out
    }

    /// Split a window in half on a sentence boundary closest to the midpoint.
    /// Returns one element if the window cannot be meaningfully halved.
    static func splitWindowInHalf(_ window: String) -> [String] {
        let sentences = ChunkIndexer.splitSentences(window)
        guard sentences.count > 1 else {
            // No sentence boundary; halve by character count as a last resort.
            let mid = window.index(window.startIndex, offsetBy: window.count / 2)
            return [String(window[..<mid]), String(window[mid...])]
        }
        let halfChars = window.count / 2
        var running = 0
        var splitAt = sentences.count / 2
        for (i, s) in sentences.enumerated() {
            running += s.count + 1
            if running >= halfChars {
                splitAt = max(1, min(sentences.count - 1, i + 1))
                break
            }
        }
        let left = sentences[0..<splitAt].joined(separator: " ")
        let right = sentences[splitAt..<sentences.count].joined(separator: " ")
        return [left, right]
    }

    /// Token budget check for a candidate map-window. iOS 26.4+ uses the
    /// real tokenizer on instructions + window + schema; older OS falls back
    /// to a char heuristic. Reserves 1200 tokens for generation and a 96
    /// token buffer under the 4096 cap.
    static func tokenBudgetSafe(_ window: String, instructions: String) async -> Bool {
        if #available(iOS 26.4, *) {
            do {
                let model = SystemLanguageModel.default
                let schema = MeetingSummary.generationSchema
                let windowTokens = try await model.tokenCount(for: window)
                let instrTokens = try await model.tokenCount(for: Instructions(instructions))
                let schemaTokens = try await model.tokenCount(for: schema)
                let total = windowTokens + instrTokens + schemaTokens + 1200
                return total < 4_000
            } catch {
                return window.count < 4_500
            }
        } else {
            return window.count < 4_500
        }
    }

    /// Materialize a partially-generated summary, defaulting any nil array
    /// fields to empty so we never surface a half-formed structure to the UI.
    static func materialize(_ partial: MeetingSummary.PartiallyGenerated) -> MeetingSummary {
        let rawActions = partial.actionItems ?? []
        let actions: [ActionItem] = rawActions.compactMap { item in
            guard let desc = item.description, !desc.isEmpty else { return nil }
            let owner = sanitizeOwner(item.owner ?? nil)
            return ActionItem(description: desc, owner: owner)
        }
        return MeetingSummary(
            title: (partial.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: partial.decisions ?? [],
            actionItems: actions,
            topics: partial.topics ?? [],
            openQuestions: partial.openQuestions ?? []
        )
    }

    /// Drop owner strings the LLM emits as a stand-in for nil. Empty after
    /// trim also collapses to nil so the UI's `!owner.isEmpty` guard works.
    static func sanitizeOwner(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if ownerSentinels.contains(trimmed.lowercased()) { return nil }
        return trimmed
    }

    /// Recursive pair-wise reduce. Reducing in halves keeps each merge bounded
    /// and balanced so a few noisy windows can't dominate the dedup. Capped at
    /// depth 3 to mirror `summarizeWindowWithSplit`'s recursion ceiling and
    /// flatten on small lists.
    static func reduce(_ partials: [MeetingSummary], depth: Int = 0) -> MeetingSummary {
        if partials.count <= 1 { return partials.first ?? .empty }
        if depth >= 3 || partials.count <= 3 {
            return merge(partials)
        }
        let mid = partials.count / 2
        let left = reduce(Array(partials[..<mid]), depth: depth + 1)
        let right = reduce(Array(partials[mid...]), depth: depth + 1)
        return merge([left, right])
    }

    /// Deterministic merge: dedupe by case-insensitive trimmed text, preserve
    /// first-seen order so the meeting reads chronologically. ActionItem
    /// dedup keys on description; first non-nil sanitized owner wins. Caps
    /// applied to keep the merged summary scannable on a phone screen.
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
                let cleanedOwner = sanitizeOwner(action.owner)
                if var existing = actionsByKey[key] {
                    if (existing.owner?.isEmpty ?? true), let owner = cleanedOwner {
                        existing.owner = owner
                        actionsByKey[key] = existing
                    }
                } else {
                    actionsByKey[key] = ActionItem(description: desc, owner: cleanedOwner)
                    actionOrder.append(key)
                }
            }
        }

        let mergedActions = actionOrder.compactMap { actionsByKey[$0] }.prefix(20)
        // Pick the first non-empty title across windows. Windows share the
        // meeting subject, and the first window — covering the meeting's
        // opening minutes — almost always carries the framing the speakers
        // use to introduce the topic. Sanitization happens downstream at
        // the persistence boundary.
        let mergedTitle = partials
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        let merged = MeetingSummary(
            title: mergedTitle,
            decisions: Array(decisions.values.prefix(15)),
            actionItems: Array(mergedActions),
            topics: Array(topics.values.prefix(12)),
            openQuestions: Array(openQuestions.values.prefix(10))
        )
        let totalItems = merged.decisions.count + merged.topics.count
            + merged.actionItems.count + merged.openQuestions.count
        if partials.count > 1 && totalItems == 0 {
            staticLog.warning("merge of \(partials.count, privacy: .public) partials yielded empty summary — likely streaming failures in chunk LLM calls")
        }
        return merged
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
