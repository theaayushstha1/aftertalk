import SwiftData
import SwiftUI

/// Quiet Studio editorial layout: warm sand background, big "Meetings" title,
/// 3-column stat card, sectioned hairline-separated rows. No List/insetGrouped
/// chrome — every divider is a 0.5pt rule and the only "card" is the stats
/// header.
struct MeetingsListView: View {
    let qaContext: QAContext?
    @Environment(\.atPalette) private var palette
    @Environment(PrivacyMonitor.self) private var privacy
    @Query(sort: \Meeting.recordedAt, order: .reverse) private var meetings: [Meeting]

    @State private var renameTarget: Meeting?
    @State private var renameDraft = ""
    @State private var deleteTarget: Meeting?
    @State private var actionError: String?
    @State private var navMeetingId: UUID?
    @State private var openSearch = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                palette.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        if meetings.isEmpty {
                            emptyState
                        } else {
                            sections
                        }
                    }
                    .padding(.bottom, 110)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: UUID.self) { id in
                if let m = meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(meeting: m, qaContext: qaContext)
                } else {
                    Text("Meeting not found.")
                }
            }
            .navigationDestination(isPresented: $openSearch) {
                SearchView()
            }
            .alert("Rename meeting", isPresented: renameBinding, presenting: renameTarget) { target in
                TextField("Title", text: $renameDraft)
                    .textInputAutocapitalization(.words)
                Button("Save") { commitRename(target) }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog(
                "Delete this meeting?",
                isPresented: deleteBinding,
                presenting: deleteTarget
            ) { target in
                Button("Delete", role: .destructive) { commitDelete(target) }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { target in
                Text("\"\(target.title)\" will be permanently removed from this device, including its transcript and chat.")
            }
            .alert("Action failed", isPresented: errorBinding, presenting: actionError) { _ in
                Button("OK") { actionError = nil }
            } message: { msg in
                Text(msg)
            }
        }
        .atTheme()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                QSEyebrow(dateEyebrow, color: palette.faint)
                Spacer()
                PrivacyBadge(state: privacy.state, compact: true)
            }
            .padding(.top, AT.Space.safeTop)
            .padding(.bottom, 10)

            QSTitle(text: "Meetings", size: 44, tracking: -1.6, color: palette.ink)
                .padding(.bottom, 18)

            statCard
                .padding(.bottom, 14)

            searchAffordance
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }

    private var dateEyebrow: String {
        Date.now.formatted(.dateTime.weekday(.abbreviated).month(.wide).day())
    }

    private var statCard: some View {
        let totalSec = meetings.reduce(0) { $0 + $1.durationSeconds }
        let totalHours = totalSec / 3600
        let fresh = meetings.filter {
            Calendar.current.isDateInToday($0.recordedAt)
        }.count
        let hoursLabel: String = totalHours >= 1
            ? String(format: "%.1fh", totalHours)
            : String(format: "%dm", Int((totalSec / 60).rounded()))
        return HStack(spacing: 0) {
            QSStat(value: "\(meetings.count)", label: "Captured", valueColor: palette.ink)
            Spacer()
            QSStat(value: hoursLabel, label: "On record", valueColor: palette.ink)
            Spacer()
            QSStat(value: "\(fresh)", label: "Fresh today", valueColor: palette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: AT.Radius.base * 1.4, style: .continuous)
                .fill(palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AT.Radius.base * 1.4, style: .continuous)
                        .stroke(palette.line, lineWidth: 0.5)
                )
        )
    }

    private var searchAffordance: some View {
        Button { openSearch = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                Text("Search across every meeting…")
                    .font(.atBody(14))
                Spacer()
                Text("\(meetings.count) IDX")
                    .font(.atMono(10, weight: .medium))
                    .tracking(0.4)
            }
            .foregroundStyle(palette.faint)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AT.Radius.base * 1.2, style: .continuous)
                    .fill(palette.surfaceAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: AT.Radius.base * 1.2, style: .continuous)
                            .stroke(palette.line, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            QSEyebrow("No meetings yet", color: palette.faint)
            QSBody(text: "Tap the dot to capture your first meeting. Everything stays on this device.",
                   color: palette.mute)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
    }

    // MARK: - Sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(buckets, id: \.0) { (title, items) in
                section(title: title, rows: items)
            }
        }
        .padding(.horizontal, 24)
    }

    private func section(title: String, rows: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                QSEyebrow(title, color: palette.faint)
                Spacer()
                Text(String(format: "%02d", rows.count))
                    .font(.atMono(10, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(palette.faint)
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
            .overlay(alignment: .top) { QSDivider() }

            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, m in
                MeetingRow(
                    meeting: m,
                    isFirst: idx == 0,
                    isFresh: Calendar.current.isDateInToday(m.recordedAt) && idx == 0,
                    onOpen: { navMeetingId = m.id },
                    onRename: {
                        renameDraft = m.title
                        renameTarget = m
                    },
                    onDelete: { deleteTarget = m }
                )
            }
        }
        .padding(.top, 22)
        .background(
            NavigationLink(value: navMeetingId) { EmptyView() }
                .opacity(0)
        )
        .onChange(of: navMeetingId) { _, newValue in
            // SwiftUI consumes the value automatically; clear so the same row
            // can be opened twice.
            if newValue != nil {
                DispatchQueue.main.async { navMeetingId = nil }
            }
        }
    }

    private var buckets: [(String, [Meeting])] {
        let cal = Calendar.current
        let now = Date.now
        var today: [Meeting] = []
        var yesterday: [Meeting] = []
        var thisWeek: [Meeting] = []
        var earlier: [Meeting] = []
        for m in meetings {
            if cal.isDateInToday(m.recordedAt) { today.append(m) }
            else if cal.isDateInYesterday(m.recordedAt) { yesterday.append(m) }
            else if let days = cal.dateComponents([.day], from: m.recordedAt, to: now).day, days < 7 { thisWeek.append(m) }
            else { earlier.append(m) }
        }
        var out: [(String, [Meeting])] = []
        if !today.isEmpty { out.append(("Today", today)) }
        if !yesterday.isEmpty { out.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { out.append(("Earlier this week", thisWeek)) }
        if !earlier.isEmpty {
            let monthKey = earlier.first.map { now.distance(toMonthOf: $0.recordedAt) } ?? "Earlier"
            out.append((monthKey, earlier))
        }
        return out
    }

    // MARK: - Mutations

    private func commitRename(_ meeting: Meeting) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !trimmed.isEmpty, trimmed != meeting.title else { return }
        guard let repository = qaContext?.repository else {
            actionError = "Storage not ready yet."
            return
        }
        let id = meeting.id
        Task {
            do {
                try await repository.renameMeeting(id, to: trimmed)
            } catch {
                await MainActor.run { actionError = "Rename failed: \(error)" }
            }
        }
    }

    private func commitDelete(_ meeting: Meeting) {
        deleteTarget = nil
        guard let repository = qaContext?.repository else {
            actionError = "Storage not ready yet."
            return
        }
        let id = meeting.id
        Task {
            do {
                try await repository.deleteMeeting(id)
            } catch {
                await MainActor.run { actionError = "Delete failed: \(error)" }
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }
}

// MARK: - Row

private struct MeetingRow: View {
    let meeting: Meeting
    let isFirst: Bool
    let isFresh: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.atPalette) private var palette

    var body: some View {
        NavigationLink(value: meeting.id) {
            HStack(alignment: .top, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if isFresh {
                        Circle()
                            .fill(palette.accent)
                            .frame(width: 4, height: 4)
                            .overlay(
                                Circle()
                                    .stroke(palette.accent.opacity(0.3), lineWidth: 3)
                            )
                            .padding(.top, 22)
                    }
                }
                .frame(width: 10, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    titleRow
                    if let s = meeting.summary, let preview = preview(from: s) {
                        Text(preview)
                            .font(.atBody(13))
                            .foregroundStyle(palette.mute)
                            .lineLimit(2)
                            .lineSpacing(2)
                            .padding(.bottom, 4)
                    }
                    metaRow
                }
            }
            .padding(.vertical, 15)
            .padding(.leading, isFresh ? 0 : 0)
            .overlay(alignment: .top) {
                if !isFirst { QSDivider() }
            }
            .contentShape(Rectangle())
            // NavigationLink inherits the parent's `.tint(palette.accent)` and
            // tries to recolor every Text inside. Force palette.ink so titles
            // and metadata stay legible.
            .foregroundStyle(palette.ink)
        }
        .buttonStyle(.plain)
        .tint(palette.ink)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.indigo)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(meeting.title)
                .font(.atDisplay(17, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(Color(red: 0.12, green: 0.10, blue: 0.08))
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(timeText)
                .font(.atMono(11, weight: .medium))
                .monospacedDigit()
                .foregroundColor(Color(red: 0.52, green: 0.47, blue: 0.38))
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(durationText)
                .monospacedDigit()
            dot
            Text(speakersText)
            if let count = actionCount {
                dot
                Text("\(count) action\(count == 1 ? "" : "s")")
                    .foregroundStyle(palette.accent)
            }
            if let topic = leadTopic {
                dot
                Text(topic.lowercased())
            }
            Spacer()
        }
        .font(.atMono(11, weight: .medium))
        .tracking(0.2)
        .foregroundStyle(palette.faint)
    }

    private var dot: some View {
        Text("·").foregroundStyle(palette.faint)
    }

    private var timeText: String {
        meeting.recordedAt.formatted(.dateTime.hour().minute())
    }

    private var durationText: String {
        let total = Int(meeting.durationSeconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    private var speakersText: String {
        let count = max(meeting.speakers.count, 1)
        return "\(count) \(count == 1 ? "voice" : "voices")"
    }

    private var actionCount: Int? {
        guard let count = meeting.summary?.actionItems.count, count > 0 else { return nil }
        return count
    }

    private var leadTopic: String? {
        meeting.summary?.topics.first
    }

    private func preview(from s: MeetingSummaryRecord) -> String? {
        if let d = s.decisions.first { return d }
        if let a = s.actionItems.first?.description { return a }
        if let t = s.topics.first { return t }
        if let q = s.openQuestions.first { return q }
        return nil
    }
}

// MARK: - Helpers

private extension Date {
    /// Returns "April" / "March" / etc. for a date earlier than this week, or
    /// "Earlier" for everything beyond a year.
    func distance(toMonthOf target: Date) -> String {
        let cal = Calendar.current
        let nowYear = cal.component(.year, from: self)
        let targetYear = cal.component(.year, from: target)
        if nowYear != targetYear {
            return target.formatted(.dateTime.month(.wide).year())
        }
        return target.formatted(.dateTime.month(.wide))
    }
}
