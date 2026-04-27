import SwiftData
import SwiftUI

struct MeetingsListView: View {
    let qaContext: QAContext?
    @Query(sort: \Meeting.recordedAt, order: .reverse) private var meetings: [Meeting]

    var body: some View {
        NavigationStack {
            Group {
                if meetings.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet",
                        systemImage: "waveform",
                        description: Text("Record a meeting to see it here.")
                    )
                } else {
                    List {
                        ForEach(meetings) { meeting in
                            NavigationLink(value: meeting.id) {
                                MeetingRow(meeting: meeting)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
            .navigationDestination(for: UUID.self) { id in
                if let m = meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(meeting: m, qaContext: qaContext)
                } else {
                    Text("Meeting not found.")
                }
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(meeting.recordedAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                Text(durationText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let s = meeting.summary {
                summaryPreview(s)
            } else {
                Text("Summary pending…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
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
