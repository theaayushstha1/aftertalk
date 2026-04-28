import SwiftData
import SwiftUI

struct MeetingsListView: View {
    let qaContext: QAContext?
    @Query(sort: \Meeting.recordedAt, order: .reverse) private var meetings: [Meeting]
    @State private var searchText = ""
    @State private var renameTarget: Meeting?
    @State private var renameDraft = ""
    @State private var deleteTarget: Meeting?
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            Group {
                if meetings.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet",
                        systemImage: "waveform",
                        description: Text("Tap Record to capture your first meeting. Everything stays on this device.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    listBody
                }
            }
            .navigationTitle(meetings.isEmpty ? "Meetings" : "\(meetings.count) Meeting\(meetings.count == 1 ? "" : "s")")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search transcripts")
            .navigationDestination(for: UUID.self) { id in
                if let m = meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(meeting: m, qaContext: qaContext)
                } else {
                    Text("Meeting not found.")
                }
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
    }

    private var listBody: some View {
        List {
            ForEach(grouped, id: \.0) { section, items in
                Section(section) {
                    ForEach(items) { meeting in
                        NavigationLink(value: meeting.id) {
                            MeetingRow(meeting: meeting)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteTarget = meeting
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameDraft = meeting.title
                                renameTarget = meeting
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var filtered: [Meeting] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return meetings }
        return meetings.filter { m in
            m.title.lowercased().contains(trimmed)
                || m.fullTranscript.lowercased().contains(trimmed)
        }
    }

    /// Bucket meetings by recency so a long history scrolls predictably.
    /// Order is preserved from the @Query (recordedAt desc).
    private var grouped: [(String, [Meeting])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [Meeting])] = []
        var todayItems: [Meeting] = []
        var yesterdayItems: [Meeting] = []
        var weekItems: [Meeting] = []
        var olderItems: [Meeting] = []
        for m in filtered {
            if cal.isDateInToday(m.recordedAt) { todayItems.append(m) }
            else if cal.isDateInYesterday(m.recordedAt) { yesterdayItems.append(m) }
            else if let days = cal.dateComponents([.day], from: m.recordedAt, to: now).day, days < 7 { weekItems.append(m) }
            else { olderItems.append(m) }
        }
        if !todayItems.isEmpty { buckets.append(("Today", todayItems)) }
        if !yesterdayItems.isEmpty { buckets.append(("Yesterday", yesterdayItems)) }
        if !weekItems.isEmpty { buckets.append(("Earlier this week", weekItems)) }
        if !olderItems.isEmpty { buckets.append(("Earlier", olderItems)) }
        return buckets
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

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(2)
            metaRow
            if let s = meeting.summary {
                summaryPreview(s)
            } else {
                Text("Summary pending…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Label(durationText, systemImage: "clock")
            if !meeting.speakers.isEmpty {
                Text("·")
                Label("\(meeting.speakers.count)", systemImage: "person.2.fill")
            }
            if !meeting.chunks.isEmpty {
                Text("·")
                Label("\(meeting.chunks.count)", systemImage: "rectangle.stack")
            }
            Spacer()
            Text(meeting.recordedAt, format: .dateTime.month().day().hour().minute())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private func summaryPreview(_ s: MeetingSummaryRecord) -> some View {
        let line = s.decisions.first
            ?? s.actionItems.first?.description
            ?? s.topics.first
            ?? s.openQuestions.first
            ?? "No structured items."
        return Text(line)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.top, 2)
    }

    private var durationText: String {
        let total = Int(meeting.durationSeconds.rounded())
        let m = total / 60
        let s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
