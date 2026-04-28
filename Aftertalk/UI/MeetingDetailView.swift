import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    let qaContext: QAContext?
    @State private var selectedTab: Tab = .summary

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case chat = "Chat"
        var id: String { rawValue }
    }

    init(meeting: Meeting, qaContext: QAContext? = nil) {
        self.meeting = meeting
        self.qaContext = qaContext
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            switch selectedTab {
            case .summary, .transcript:
                ScrollView {
                    Group {
                        switch selectedTab {
                        case .summary: summaryView
                        case .transcript: transcriptView
                        case .chat: EmptyView()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            case .chat:
                chatView
            }
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Real teardown: when the user pops back to the meetings list,
            // cancel any ongoing Q&A and deactivate the .playAndRecord
            // session so the mic indicator clears. Tab-switching within this
            // view does NOT deactivate (see ChatThreadView.onDisappear).
            if let ctx = qaContext {
                Task {
                    await ctx.orchestrator.cancel()
                    await AudioSessionManager.shared.deactivate()
                }
            }
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        if let s = meeting.summary {
            VStack(alignment: .leading, spacing: 16) {
                section("Decisions", items: s.decisions)
                actionItemsSection(s.actionItems)
                section("Topics", items: s.topics)
                section("Open questions", items: s.openQuestions)
                Text("Generated in \(Int(s.generationLatencyMillis)) ms · \(s.generatedAt, format: .dateTime.hour().minute())")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            ContentUnavailableView(
                "Summary not generated yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Foundation Models was unavailable or the recording was too short.")
            )
        }
    }

    @ViewBuilder
    private var chatView: some View {
        if let ctx = qaContext {
            ChatThreadView(
                meeting: meeting,
                orchestrator: ctx.orchestrator,
                questionASR: ctx.questionASR,
                repository: ctx.repository
            )
        } else {
            ContentUnavailableView(
                "Chat unavailable",
                systemImage: "exclamationmark.bubble",
                description: Text("The Q&A pipeline failed to initialize. Foundation Models may be unavailable on this device.")
            )
        }
    }

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if meeting.fullTranscript.isEmpty {
                Text("No transcript captured.")
                    .foregroundStyle(.secondary)
            } else {
                Text(meeting.fullTranscript)
                    .font(.system(.body, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionItemsSection(_ items: [ActionItemRecord]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Action items")
                    .font(.headline)
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description)
                            if let owner = item.owner, !owner.isEmpty {
                                Text(owner)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
