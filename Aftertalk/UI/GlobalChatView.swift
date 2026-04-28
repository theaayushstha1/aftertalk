import SwiftData
import SwiftUI

/// Cross-meeting chat surface. Queries the singleton global `ChatThread`
/// (`isGlobal == true`, `meetingId == nil`) and asks every question via
/// `QAOrchestrator.askGlobal`, which lets `HierarchicalRetriever` fire
/// Layer-1 (summary search) → Layer-2 (chunk search inside the top
/// meetings). Citation pills render the source meeting title so the user
/// can tell which meeting a claim came from.
struct GlobalChatView: View {
    let qaContext: QAContext?
    @Query(sort: \Meeting.recordedAt, order: .reverse) private var meetings: [Meeting]
    @Query private var messages: [ChatMessage]
    @State private var holding = false
    @State private var lastError: String?
    @State private var threadId: UUID?
    @State private var lastResult: QAResult?

    init(qaContext: QAContext?) {
        self.qaContext = qaContext
        self._messages = Query(
            filter: #Predicate<ChatMessage> { msg in
                msg.thread?.isGlobal == true
            },
            sort: \ChatMessage.timestamp,
            order: .forward
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let ctx = qaContext {
                    chatBody(ctx: ctx)
                } else {
                    ContentUnavailableView(
                        "Cross-meeting Q&A unavailable",
                        systemImage: "exclamationmark.bubble",
                        description: Text("Foundation Models may be unavailable on this device.")
                    )
                }
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Label("\(meetings.count) meetings", systemImage: "rectangle.stack.badge.person.crop")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDisappear {
                if let ctx = qaContext {
                    Task {
                        await ctx.orchestrator.cancel()
                        await ctx.orchestrator.cleanupTTS()
                        await AudioSessionManager.shared.deactivate()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatBody(ctx: QAContext) -> some View {
        VStack(spacing: 0) {
            messageList(ctx: ctx)
            statusStrip
            holdButton(ctx: ctx)
        }
        .task {
            await ensureThread(repository: ctx.repository)
            await ctx.questionASR.prewarm()
            await ctx.orchestrator.warmTTS()
        }
    }

    private func messageList(ctx: QAContext) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "Hold the mic to ask",
                            systemImage: "rectangle.stack.badge.person.crop",
                            description: Text("Ask a question about anything across all your meetings. Aftertalk synthesizes from every transcript on this device.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(messages) { msg in
                            CrossMeetingBubble(
                                message: msg,
                                titlesById: titlesById,
                                orchestrator: ctx.orchestrator
                            )
                            .id(msg.id)
                        }
                    }
                    if holding {
                        listeningRow(ctx: ctx)
                    } else if ctx.orchestrator.stage != .idle && !ctx.orchestrator.liveAnswer.isEmpty {
                        streamingRow(ctx: ctx)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if let err = lastError {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        } else if let r = lastResult, let ttfsw = r.ttfswMillis {
            Text("TTFSW \(Int(ttfsw)) ms · total \(Int(r.totalMillis)) ms · \(r.citations.count) citations")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
    }

    private func listeningRow(ctx: QAContext) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(.red)
            Text(ctx.questionASR.liveTranscript.isEmpty ? "Listening…" : ctx.questionASR.liveTranscript)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func streamingRow(ctx: QAContext) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "ellipsis.bubble")
                .foregroundStyle(.secondary)
            Text(ctx.orchestrator.liveAnswer)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func holdButton(ctx: QAContext) -> some View {
        VStack(spacing: 8) {
            Text(holding ? "Release to ask" : "Hold to ask · across all meetings")
                .font(.caption)
                .foregroundStyle(.secondary)
            Circle()
                .fill(holding ? Color.red : Color.accentColor)
                .frame(width: 80, height: 80)
                .overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(holding ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.15), value: holding)
                .gesture(holdGesture(ctx: ctx))
        }
        .padding(.vertical, 16)
    }

    private func holdGesture(ctx: QAContext) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !holding {
                    holding = true
                    Task { await beginHold(ctx: ctx) }
                }
            }
            .onEnded { _ in
                if holding {
                    holding = false
                    Task { await endHold(ctx: ctx) }
                }
            }
    }

    private var titlesById: [UUID: String] {
        Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.title) })
    }

    private func ensureThread(repository: MeetingsRepository) async {
        guard threadId == nil else { return }
        do {
            threadId = try await repository.globalChatThreadId()
        } catch {
            lastError = "thread: \(error)"
        }
    }

    private func beginHold(ctx: QAContext) async {
        lastError = nil
        await ctx.orchestrator.cancel()
        do {
            try await ctx.questionASR.start()
        } catch {
            holding = false
            lastError = "\(error)"
        }
    }

    private func endHold(ctx: QAContext) async {
        let question = await ctx.questionASR.stop()
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let threadId else {
            lastError = "thread not ready"
            return
        }
        do {
            try await ctx.repository.appendChatMessage(threadId: threadId, role: "user", text: question)
        } catch {
            lastError = "save question: \(error)"
            return
        }
        let result = await ctx.orchestrator.askGlobal(question: question, repository: ctx.repository)
        if let result {
            lastResult = result
            do {
                try await ctx.repository.appendChatMessage(
                    threadId: threadId,
                    role: "assistant",
                    text: result.answer,
                    citations: result.citations
                )
            } catch {
                lastError = "save answer: \(error)"
            }
        }
    }
}

/// Bubble variant for the global chat. Identical to MessageBubble in
/// ChatThreadView except the citation pills resolve their meeting title
/// from the live `meetings` query and render "[title] · MM:SS" so the
/// user can tell which meeting a claim came from.
private struct CrossMeetingBubble: View {
    let message: ChatMessage
    let titlesById: [UUID: String]
    let orchestrator: QAOrchestrator

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 6) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
                if message.role == "assistant" { speakerControl }
                if !message.citations.isEmpty { citationsRow }
            }
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }

    private var speakerControl: some View {
        Button {
            Task { await orchestrator.replay(message.text) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                Text("Replay")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var bubbleColor: Color {
        message.role == "user" ? Color.accentColor : Color(.secondarySystemBackground)
    }

    private var citationsRow: some View {
        // Collapse multiple hits from the same meeting into a single pill so
        // a 6-chunk answer that all came from one meeting doesn't render six
        // identical pills. Order preserved from the citation array (which is
        // relevance-sorted).
        let unique = uniqueByMeeting(message.citations)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(unique.prefix(4), id: \.id) { c in
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack")
                        .font(.caption2)
                    Text(citationLabel(c))
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
            }
            if unique.count > 4 {
                Text("+\(unique.count - 4) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func citationLabel(_ c: ChunkCitation) -> String {
        // 28-char clip keeps the pill on one line at iPhone widths even when
        // the bubble is at full inset. Topic-derived titles average 18-22
        // chars after the auto-title pass (e.g. "Pricing tiers · Q3 hiring"),
        // so this rarely truncates real titles — only the legacy fragment
        // titles that pre-date the topic-rename get clipped.
        let title = titlesById[c.meetingId].map { String($0.prefix(28)) } ?? "Unknown meeting"
        return "\(title) · \(timestamp(c.startSec))"
    }

    private func uniqueByMeeting(_ citations: [ChunkCitation]) -> [ChunkCitation] {
        var seen = Set<UUID>()
        var out: [ChunkCitation] = []
        for c in citations where seen.insert(c.meetingId).inserted {
            out.append(c)
        }
        return out
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
