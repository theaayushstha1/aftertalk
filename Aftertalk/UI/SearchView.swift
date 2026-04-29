import SwiftData
import SwiftUI

/// Cross-meeting search surface. Four modes share one `TextField` and one
/// result list; only the data source per mode differs.
///
/// - `.semantic` runs the query through `NLContextualEmbeddingService` and
///   pulls top-K chunks from `SwiftDataVectorStore` across every meeting.
/// - `.verbatim` is a case-insensitive substring match over `TranscriptChunk`
///   text — handy when you remember the exact phrase.
/// - `.people` lists distinct `SpeakerLabel` display names; tapping a name
///   filters chunks by that speaker.
/// - `.decisions` pulls each meeting's `MeetingSummaryRecord.decisions`.
///
/// Heavy lifting (embedding + cosine sweep) happens off-main inside a
/// debounced `.task(id:)`; UI binds via `@State` arrays.
struct SearchView: View {
    @Environment(\.atPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Meeting.recordedAt, order: .reverse) private var meetings: [Meeting]

    @State private var query: String = ""
    @State private var mode: SearchMode = .semantic
    @State private var results: [SearchHit] = []
    @State private var people: [PersonHit] = []
    @State private var decisions: [DecisionHit] = []
    @State private var selectedSpeaker: String?
    @State private var isSearching = false

    var body: some View {
        ZStack(alignment: .top) {
            palette.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchField
                        .padding(.top, 18)
                    modePills
                        .padding(.top, 14)
                    Group {
                        switch mode {
                        case .semantic, .verbatim:
                            chunkResults
                        case .people:
                            peopleResults
                        case .decisions:
                            decisionResults
                        }
                    }
                    .padding(.top, 22)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 80)
            }
        }
        .navigationBarHidden(true)
        .task(id: searchKey) {
            // Debounce keystrokes by 200ms and only run the heavy path when
            // the input has settled. `.task(id:)` cancels the previous Task
            // for free, so we just sleep first and let the runtime kill us
            // if a newer keystroke arrives.
            try? await Task.sleep(for: .milliseconds(200))
            await runSearch()
        }
        .atTheme()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .medium))
                    Text("Meetings")
                        .font(.atBody(13, weight: .medium))
                }
                .foregroundStyle(palette.mute)
            }
            .buttonStyle(.plain)
            .padding(.top, AT.Space.safeTop)

            QSEyebrow("Search", color: palette.faint)
            QSTitle(
                text: "What were you\nsaying about\u{2026}",
                size: 32,
                tracking: -1.5,
                color: palette.ink
            )
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.mute)
            TextField(mode.placeholder, text: $query)
                .font(.atBody(14))
                .foregroundStyle(palette.ink)
                .tint(palette.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(palette.faint)
                }
                .buttonStyle(.plain)
            }
            if isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .tint(palette.faint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AT.Radius.base * 1.2, style: .continuous)
                .fill(palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AT.Radius.base * 1.2, style: .continuous)
                        .stroke(palette.line, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Mode pills

    private var modePills: some View {
        // 4 pills must fit on a 320pt-wide content column (iPhone Air width
        // minus 24pt horizontal padding). Pre-Day-6 they wrapped to two lines
        // because each label was ~9 chars × 11pt mono with generous padding.
        // Now: tighter font + smaller padding + equal-width slots so labels
        // never truncate or wrap.
        HStack(spacing: 6) {
            ForEach(SearchMode.allCases) { m in
                modePill(m)
            }
        }
    }

    @ViewBuilder
    private func modePill(_ m: SearchMode) -> some View {
        let active = m == mode
        Button {
            withAnimation(AT.Motion.standard) {
                mode = m
                selectedSpeaker = nil
            }
        } label: {
            Text(m.label.uppercased())
                .font(.atMono(9.5, weight: .semibold))
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(active ? palette.ink : palette.mute)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(active ? palette.surface : Color.clear)
                        .overlay(
                            Capsule().stroke(active ? palette.lineStrong : palette.line, lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chunk results (semantic + verbatim)

    @ViewBuilder
    private var chunkResults: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyHint("Start typing to search the meeting history.")
        } else if results.isEmpty && !isSearching {
            emptyHint("Nothing matched. Try a different phrase or switch modes.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                QSEyebrow(resultsHeader, color: palette.faint)
                    .padding(.bottom, 14)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { hit in
                        NavigationLink(value: hit.meetingId) {
                            ResultRow(hit: hit, query: mode == .verbatim ? query : nil)
                        }
                        .buttonStyle(.plain)
                        QSDivider()
                    }
                }
            }
        }
    }

    private var resultsHeader: String {
        let count = results.count
        let suffix = count == 1 ? "match" : "matches"
        return "\(count) \(suffix) \u{00B7} \(mode.label)"
    }

    // MARK: - People results

    @ViewBuilder
    private var peopleResults: some View {
        if let speaker = selectedSpeaker {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(AT.Motion.standard) {
                        selectedSpeaker = nil
                        results = []
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("All voices")
                            .font(.atBody(12, weight: .medium))
                    }
                    .foregroundStyle(palette.faint)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)

                QSEyebrow("\(speaker) \u{00B7} \(results.count) chunks", color: palette.faint)
                    .padding(.bottom, 14)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { hit in
                        NavigationLink(value: hit.meetingId) {
                            ResultRow(hit: hit, query: nil)
                        }
                        .buttonStyle(.plain)
                        QSDivider()
                    }
                }
            }
        } else if people.isEmpty {
            emptyHint("No speakers labelled yet. Record a meeting and diarization will fill this in.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                QSEyebrow("\(people.count) voices across \(meetings.count) meetings", color: palette.faint)
                    .padding(.bottom, 14)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(people) { p in
                        Button {
                            withAnimation(AT.Motion.standard) {
                                selectedSpeaker = p.displayName
                                loadChunksForSpeaker(p.displayName)
                            }
                        } label: {
                            PersonRow(person: p)
                        }
                        .buttonStyle(.plain)
                        QSDivider()
                    }
                }
            }
        }
    }

    // MARK: - Decision results

    @ViewBuilder
    private var decisionResults: some View {
        if decisions.isEmpty {
            emptyHint("No decisions captured yet. They land here once a meeting's summary is distilled.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                QSEyebrow("\(decisions.count) decisions across \(meetings.count) meetings", color: palette.faint)
                    .padding(.bottom, 14)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(decisions) { d in
                        NavigationLink(value: d.meetingId) {
                            DecisionRow(decision: d)
                        }
                        .buttonStyle(.plain)
                        QSDivider()
                    }
                }
            }
        }
    }

    // MARK: - Empty state helper

    private func emptyHint(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            QSEyebrow(mode.emptyEyebrow, color: palette.faint)
            QSBody(text: text, color: palette.mute)
        }
        .padding(.top, 24)
    }

    // MARK: - Search dispatch

    /// Single key for `.task(id:)` so any change to query OR mode reruns.
    private var searchKey: String { "\(mode.rawValue)|\(query)" }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .semantic:
            guard !trimmed.isEmpty else { results = []; return }
            isSearching = true
            defer { isSearching = false }
            results = await semanticSearch(trimmed)
        case .verbatim:
            guard !trimmed.isEmpty else { results = []; return }
            results = verbatimSearch(trimmed)
        case .people:
            people = peopleList(filter: trimmed)
            if let s = selectedSpeaker {
                loadChunksForSpeaker(s)
            }
        case .decisions:
            decisions = decisionList(filter: trimmed)
        }
    }

    // MARK: - Mode implementations

    private func semanticSearch(_ text: String) async -> [SearchHit] {
        do {
            let embeddings = try NLContextualEmbeddingService()
            let store = SwiftDataVectorStore(modelContainer: modelContext.container)
            let queryVec = try await embeddings.embed(text)
            let hits = try await store.searchChunks(query: queryVec, scopedTo: nil, topK: 12)
            let titlesById = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.title) })
            let raw = hits.map { h in
                SearchHit(
                    chunkId: h.chunkId,
                    meetingId: h.meetingId,
                    meetingTitle: titlesById[h.meetingId] ?? "Untitled meeting",
                    timestampLabel: Self.formatTimecode(h.startSec),
                    speaker: h.speakerName,
                    text: h.text,
                    score: h.score
                )
            }
            return Self.dedupeHits(raw)
        } catch {
            return []
        }
    }

    private func verbatimSearch(_ text: String) -> [SearchHit] {
        let needle = text.lowercased()
        var raw: [SearchHit] = []
        for meeting in meetings {
            for chunk in meeting.chunks where chunk.text.lowercased().contains(needle) {
                raw.append(SearchHit(
                    chunkId: chunk.id,
                    meetingId: meeting.id,
                    meetingTitle: meeting.title,
                    timestampLabel: Self.formatTimecode(chunk.startSec),
                    speaker: chunk.speakerName,
                    text: chunk.text,
                    score: 0
                ))
                if raw.count >= 400 { break }
            }
        }
        return Self.dedupeHits(raw)
    }

    /// Collapse adjacent or scattered hits whose `(meetingId, text)` is the
    /// same. Two paths land here:
    ///   1. The transcript itself contains a recurring phrase that the chunker
    ///      split across overlapping windows — same meeting, same text, two
    ///      chunkIds.
    ///   2. The user accidentally re-ran the pipeline on the same recording
    ///      and we have two meetings with the same chunk text.
    /// Either way the user wants one row per unique substantive hit.
    private static func dedupeHits(_ hits: [SearchHit]) -> [SearchHit] {
        var seen = Set<String>()
        var out: [SearchHit] = []
        out.reserveCapacity(hits.count)
        for h in hits {
            let normalized = h.text
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            // Same exact phrase across the same meeting collapses; same
            // phrase in a different meeting is allowed since cross-meeting
            // hits are genuinely useful information.
            let key = "\(h.meetingId.uuidString)|\(normalized)"
            if seen.insert(key).inserted {
                out.append(h)
            }
        }
        return out
    }

    private func peopleList(filter: String) -> [PersonHit] {
        var byName: [String: PersonHit] = [:]
        let needle = filter.lowercased()
        for meeting in meetings {
            for label in meeting.speakers {
                let name = label.displayName
                if !needle.isEmpty && !name.lowercased().contains(needle) { continue }
                var existing = byName[name] ?? PersonHit(displayName: name, meetingCount: 0, meetingTitles: [])
                existing.meetingCount += 1
                if existing.meetingTitles.count < 3 {
                    existing.meetingTitles.append(meeting.title)
                }
                byName[name] = existing
            }
        }
        return byName.values.sorted { lhs, rhs in
            if lhs.meetingCount != rhs.meetingCount { return lhs.meetingCount > rhs.meetingCount }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func loadChunksForSpeaker(_ name: String) {
        var out: [SearchHit] = []
        for meeting in meetings {
            for chunk in meeting.chunks where chunk.speakerName == name {
                out.append(SearchHit(
                    chunkId: chunk.id,
                    meetingId: meeting.id,
                    meetingTitle: meeting.title,
                    timestampLabel: Self.formatTimecode(chunk.startSec),
                    speaker: chunk.speakerName,
                    text: chunk.text,
                    score: 0
                ))
                if out.count >= 200 { break }
            }
        }
        results = out
    }

    private func decisionList(filter: String) -> [DecisionHit] {
        let needle = filter.lowercased()
        // Dedupe on normalized text globally — if the same decision phrase
        // shows up twice in the same meeting (LLM emitted it in two list
        // entries) or across two meetings (same audio re-processed), the
        // user only wants one row. Keep the first occurrence we encounter
        // walking newest-first; later ones are silently dropped.
        var seen = Set<String>()
        var out: [DecisionHit] = []
        for meeting in meetings {
            guard let summary = meeting.summary else { continue }
            for (idx, decision) in summary.decisions.enumerated() {
                if !needle.isEmpty && !decision.lowercased().contains(needle) { continue }
                let normalized = decision
                    .lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                out.append(DecisionHit(
                    id: "\(meeting.id.uuidString)#\(idx)",
                    meetingId: meeting.id,
                    meetingTitle: meeting.title,
                    recordedAt: meeting.recordedAt,
                    text: decision
                ))
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func formatTimecode(_ sec: Double) -> String {
        let total = Int(sec.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Mode

private enum SearchMode: String, CaseIterable, Identifiable {
    case semantic, verbatim, people, decisions
    var id: String { rawValue }

    var label: String {
        switch self {
        case .semantic: return "Semantic"
        case .verbatim: return "Verbatim"
        case .people: return "People"
        case .decisions: return "Decisions"
        }
    }

    var placeholder: String {
        switch self {
        case .semantic: return "e.g. retention plan"
        case .verbatim: return "match a phrase"
        case .people: return "filter by name"
        case .decisions: return "what got decided"
        }
    }

    var emptyEyebrow: String {
        switch self {
        case .semantic: return "Across every meeting"
        case .verbatim: return "Exact match"
        case .people: return "Voices"
        case .decisions: return "Decisions"
        }
    }
}

// MARK: - Hit types

private struct SearchHit: Identifiable, Hashable {
    let chunkId: UUID
    let meetingId: UUID
    let meetingTitle: String
    let timestampLabel: String
    let speaker: String?
    let text: String
    let score: Float
    var id: UUID { chunkId }
}

private struct PersonHit: Identifiable, Hashable {
    let displayName: String
    var meetingCount: Int
    var meetingTitles: [String]
    var id: String { displayName }
}

private struct DecisionHit: Identifiable, Hashable {
    let id: String
    let meetingId: UUID
    let meetingTitle: String
    let recordedAt: Date
    let text: String
}

// MARK: - Row components

private struct ResultRow: View {
    let hit: SearchHit
    /// When non-nil, the row highlights occurrences of this substring (verbatim mode).
    let query: String?
    @Environment(\.atPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(hit.meetingTitle.uppercased())
                    .font(.atMono(10.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(palette.mute)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\u{00B7}")
                    .font(.atMono(10.5, weight: .semibold))
                    .foregroundStyle(palette.faint)
                Text(hit.timestampLabel)
                    .font(.atMono(10.5, weight: .medium))
                    .foregroundStyle(palette.faint)
                if let speaker = hit.speaker {
                    Text("\u{00B7}")
                        .font(.atMono(10.5, weight: .semibold))
                        .foregroundStyle(palette.faint)
                    Text(speaker)
                        .font(.atMono(10.5, weight: .medium))
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(highlighted)
                .font(.atBody(14))
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var highlighted: AttributedString {
        var attr = AttributedString(hit.text)
        guard let q = query, !q.isEmpty else { return attr }
        let lowerText = hit.text.lowercased()
        let lowerQuery = q.lowercased()
        var searchStart = lowerText.startIndex
        while let range = lowerText.range(of: lowerQuery, range: searchStart..<lowerText.endIndex) {
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].backgroundColor = palette.accentSoft.opacity(0.25)
                attr[attrRange].foregroundColor = palette.ink
            }
            searchStart = range.upperBound
        }
        return attr
    }
}

private struct PersonRow: View {
    let person: PersonHit
    @Environment(\.atPalette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(initials)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(palette.accent))
            VStack(alignment: .leading, spacing: 4) {
                Text(person.displayName)
                    .font(.atBody(15, weight: .medium))
                    .foregroundStyle(palette.ink)
                Text(meta)
                    .font(.atMono(10.5, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.faint)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var initials: String {
        let parts = person.displayName.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first }.map { String($0) }
        return chars.joined().uppercased()
    }

    private var meta: String {
        let countLabel = "\(person.meetingCount) meeting\(person.meetingCount == 1 ? "" : "s")"
        if person.meetingTitles.isEmpty { return countLabel }
        let titles = person.meetingTitles.joined(separator: " \u{00B7} ")
        return "\(countLabel) \u{00B7} \(titles)".uppercased()
    }
}

private struct DecisionRow: View {
    let decision: DecisionHit
    @Environment(\.atPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(decision.meetingTitle.uppercased())
                    .font(.atMono(10.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(palette.mute)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\u{00B7}")
                    .font(.atMono(10.5, weight: .semibold))
                    .foregroundStyle(palette.faint)
                Text(decision.recordedAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.atMono(10.5, weight: .medium))
                    .foregroundStyle(palette.faint)
                Spacer(minLength: 0)
            }
            Text(decision.text)
                .font(.atBody(14.5))
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
