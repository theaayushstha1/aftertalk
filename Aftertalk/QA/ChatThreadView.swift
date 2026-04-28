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
    /// Tracks the auto-rearm listen window so a fresh hold gesture can
    /// cancel it. Without this, manually grabbing the mic during the auto
    /// listen would result in two start() calls on QuestionASR — the
    /// streamer chokes when its capture session is reconfigured mid-stream.
    @State private var autoRearmTask: Task<Void, Never>?

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
            bargeInBanner
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
            // Install the auto-rearm closure on the orchestrator so a
            // mid-answer barge-in can immediately reopen the mic for a
            // short listen window without making the user find the mic
            // button again. The closure captures @State references which
            // remain valid across view rebuilds (SwiftUI proxies through
            // the underlying storage). Cleared on disappear.
            orchestrator.onAutoRearm = {
                await autoRearmListen()
            }
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
            autoRearmTask?.cancel()
            autoRearmTask = nil
            orchestrator.onAutoRearm = nil
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

    /// Banner shown after the user's voice trips the barge-in energy gate
    /// during TTS playback. We render it above the hold button (not as an
    /// overlay) so it doesn't fight with the listening row inside the
    /// scroll view. Cleared by `clearBargeIn()` the moment a fresh hold
    /// gesture starts. Auto-rearm makes this banner short-lived in
    /// practice — it shows during the ~6 s listen window and disappears
    /// when the orchestrator's next `runAsk` resets `didBargeIn`.
    @ViewBuilder
    private var bargeInBanner: some View {
        if orchestrator.didBargeIn {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("You interrupted — keep talking or hold to ask again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .transition(.opacity)
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
        // Cancel any pending auto-rearm window — the user wants to drive the
        // mic manually now. Without this, autoRearmListen's questionASR.start
        // can race against the one we're about to fire below, leaving the
        // streamer in a half-reconfigured state.
        autoRearmTask?.cancel()
        autoRearmTask = nil
        // Clear the "you interrupted" banner so it doesn't stack on top of
        // the listening row.
        orchestrator.clearBargeIn()
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

    /// Called by the orchestrator's `onAutoRearm` after a barge-in cancels the
    /// in-flight answer. Reopens QuestionASR for a short window so the user
    /// can keep speaking without finding the mic button. Auto-finalizes after
    /// `autoRearmWindowSeconds` by routing through `endHold` — same persist +
    /// ask pipeline as a manual release.
    private func autoRearmListen() async {
        autoRearmTask?.cancel()
        let task = Task { @MainActor in
            holding = true
            do {
                try await questionASR.start()
            } catch {
                holding = false
                lastError = "auto-rearm: \(error)"
                return
            }
            // 6 s gives the user enough time to say a follow-up question
            // (most are under 4 s in our golden eval) without sitting on a
            // hot mic indefinitely. They can still release/tap to finalize
            // earlier — the gesture path runs through endHold which checks
            // the same `asking` guard.
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            if Task.isCancelled { return }
            holding = false
            // Only auto-commit if we actually heard a real question. The
            // barge-in energy gate misfires on coughs, drops, AirPods clicks,
            // and Kokoro tail bleed past AEC — and ASR happily turns 6 s of
            // silence into garbled non-empty text. Without this guard, a
            // false barge-in (a) silences the in-flight answer mid-sentence
            // and (b) auto-fires a junk question from room noise. We require
            // ≥ 2 whitespace-separated tokens AND ≥ 8 trimmed chars before
            // routing through endHold; below that we just stop the mic
            // quietly and leave the user in idle with the "you interrupted"
            // banner, so the next hold-to-ask starts clean.
            let heard = questionASR.liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tokenCount = heard.split { $0.isWhitespace }.count
            if tokenCount >= 2 && heard.count >= 8 {
                await endHold()
            } else {
                _ = await questionASR.stop()
            }
        }
        autoRearmTask = task
        await task.value
        autoRearmTask = nil
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
