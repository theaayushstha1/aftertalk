import SwiftData
import SwiftUI

struct ChatThreadView: View {
    let meeting: Meeting
    let orchestrator: QAOrchestrator
    let questionASR: QuestionASR
    let repository: MeetingsRepository

    @Query private var messages: [ChatMessage]
    @State private var holding = false
    @State private var lastError: String?
    @State private var threadId: UUID?
    @State private var lastResult: QAResult?
    /// Hard gate against `endHold` running twice for one gesture. SwiftUI's
    /// `DragGesture` can fire `.onEnded` more than once when the touch is
    /// interrupted (incoming notification, route change, brief background)
    /// and the `holding` boolean alone wasn't sufficient because it gets
    /// flipped back to false immediately while the async chain is mid-flight.
    /// `asking` stays true through the entire question-persist + LLM-ask
    /// path, so a duplicate end-event hits the early-return.
    @State private var asking = false

    init(meeting: Meeting,
         orchestrator: QAOrchestrator,
         questionASR: QuestionASR,
         repository: MeetingsRepository) {
        self.meeting = meeting
        self.orchestrator = orchestrator
        self.questionASR = questionASR
        self.repository = repository
        let mid = meeting.id
        self._messages = Query(
            filter: #Predicate<ChatMessage> { msg in
                msg.thread?.meetingId == mid && msg.thread?.isGlobal == false
            },
            sort: \ChatMessage.timestamp,
            order: .forward
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            statusStrip
            holdButton
        }
        .task {
            await ensureThread()
            await questionASR.prewarm()
            // Lazy-warm Kokoro here instead of at app launch. Adding ~300 MB
            // to the resident set during the recording → summary path was
            // pushing iPhone Air over the iOS 26 foreground jetsam ceiling
            // and crashing on the first chat question. By the time the user
            // finishes holding the mic, this prewarm is hot.
            await orchestrator.warmTTS()
        }
        .onDisappear {
            // Cancel any in-flight TTS so a tab switch interrupts cleanly,
            // but DO NOT deactivate the audio session here. This view
            // unmounts every time the user toggles between the Summary /
            // Transcript / Chat segmented picker. If we deactivated while
            // TTSWorker's AVAudioEngine is still running, the next setActive
            // fails with NSOSStatusErrorDomain Code=561017449 (CLAUDE.md
            // invariant: "do NOT deactivate the audio session while I/O is
            // running"). MeetingDetailView.onDisappear takes care of the
            // real teardown when the user navigates back to the meetings
            // list.
            Task { await orchestrator.cancel() }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "Hold the mic to ask",
                            systemImage: "mic.circle",
                            description: Text("Ask a question about this meeting. Aftertalk answers using only the transcript.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg, orchestrator: orchestrator)
                                .id(msg.id)
                        }
                    }
                    if holding {
                        listeningRow
                    } else if orchestrator.stage != .idle && !orchestrator.liveAnswer.isEmpty {
                        streamingRow
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
            Text("TTFSW \(Int(ttfsw)) ms · total \(Int(r.totalMillis)) ms")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
    }

    private var listeningRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(.red)
            Text(questionASR.liveTranscript.isEmpty ? "Listening…" : questionASR.liveTranscript)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var streamingRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "ellipsis.bubble")
                .foregroundStyle(.secondary)
            Text(orchestrator.liveAnswer)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private var holdButton: some View {
        VStack(spacing: 8) {
            Text(holding ? "Release to ask" : "Hold to ask")
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
                .gesture(holdGesture)
        }
        .padding(.vertical, 16)
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !holding {
                    holding = true
                    Task { await beginHold() }
                }
            }
            .onEnded { _ in
                if holding {
                    holding = false
                    Task { await endHold() }
                }
            }
    }

    private func ensureThread() async {
        guard threadId == nil else { return }
        do {
            threadId = try await repository.chatThreadId(for: meeting.id)
        } catch {
            lastError = "thread: \(error)"
        }
    }

    private func beginHold() async {
        lastError = nil
        // Barge-in: cancel any in-flight answer + drop queued TTS so the new
        // question doesn't pile on top of the previous one.
        await orchestrator.cancel()
        do {
            try await questionASR.start()
        } catch {
            holding = false
            lastError = "\(error)"
        }
    }

    private func endHold() async {
        if asking { return }
        asking = true
        defer { asking = false }

        let question = await questionASR.stop()
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard let threadId else {
            lastError = "thread not ready"
            return
        }
        // Persist the user's question first so the bubble appears immediately.
        do {
            try await repository.appendChatMessage(threadId: threadId, role: "user", text: question)
        } catch {
            lastError = "save question: \(error)"
            return
        }
        let result = await orchestrator.ask(question: question, in: meeting)
        if let result {
            lastResult = result
            do {
                try await repository.appendChatMessage(
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

private struct MessageBubble: View {
    let message: ChatMessage
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
                if message.role == "assistant" {
                    speakerControl
                }
                if !message.citations.isEmpty {
                    citationsRow
                }
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
        HStack(spacing: 6) {
            ForEach(message.citations.prefix(3)) { c in
                Text(timestamp(c.startSec))
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
            if message.citations.count > 3 {
                Text("+\(message.citations.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
