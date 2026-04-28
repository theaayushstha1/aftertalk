import SwiftData
import SwiftUI

/// Cross-meeting chat surface, Quiet Studio refit. Queries the singleton
/// global `ChatThread` (`isGlobal == true`, `meetingId == nil`) and asks
/// every question via `QAOrchestrator.askGlobal`, which lets
/// `HierarchicalRetriever` fire Layer-1 (summary search) → Layer-2 (chunk
/// search inside the top meetings). Citation rows render the source meeting
/// title so the user can tell which meeting a claim came from.
///
/// This view is a tab root (no NavigationStack push), so no back button —
/// the scope chip + privacy badge + idle hero copy do the orientation work.
/// Logic (auto-rearm, barge-in, asking-guard) is identical to
/// `ChatThreadView`; only retrieval scope and citation rendering differ.
struct GlobalChatView: View {
    let qaContext: QAContext?

    @Query(sort: \Meeting.recordedAt, order: .reverse) private var meetings: [Meeting]
    @Query private var messages: [ChatMessage]

    @Environment(\.atPalette) private var palette

    @State private var holding = false
    @State private var lastError: String?
    @State private var threadId: UUID?
    @State private var lastResult: QAResult?
    /// See ChatThreadView.asking for the rationale. Stops one hold gesture
    /// from persisting two user messages when DragGesture.onEnded fires twice.
    @State private var asking = false
    /// Mirror of ChatThreadView.autoRearmTask — same 6 s post-barge-in window.
    @State private var autoRearmTask: Task<Void, Never>?

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
        Group {
            if let ctx = qaContext {
                chatBody(ctx: ctx)
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.bg.ignoresSafeArea())
        .atTheme()
    }

    private var unavailable: some View {
        VStack(spacing: 18) {
            Spacer()
            QSEyebrow("Cross-meeting Q&A unavailable", color: palette.faint)
            QSBody(
                text: "Foundation Models may be unavailable on this device.",
                size: 14,
                color: palette.mute
            )
            .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func chatBody(ctx: QAContext) -> some View {
        VStack(spacing: 0) {
            header
            scopeChip
            bodyArea(ctx: ctx)
            statusStrip
            bargeInBanner(ctx: ctx)
            holdFAB(ctx: ctx)
        }
        .task {
            await ensureThread(repository: ctx.repository)
            await ctx.questionASR.prewarm()
            await ctx.orchestrator.warmTTS()
            ctx.orchestrator.onAutoRearm = {
                await autoRearmListen(ctx: ctx)
            }
        }
        .onDisappear {
            autoRearmTask?.cancel()
            autoRearmTask = nil
            ctx.orchestrator.onAutoRearm = nil
            Task {
                await ctx.orchestrator.cancel()
                await ctx.orchestrator.cleanupTTS()
                await AudioSessionManager.shared.deactivate()
            }
        }
    }

    // MARK: - Header / scope

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                QSEyebrow("Aftertalk", color: palette.faint)
                Text("Across every meeting")
                    .font(.atBody(12))
                    .foregroundStyle(palette.mute)
            }
            Spacer()
            QSPrivacyBadge(compact: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, AT.Space.safeTop)
        .padding(.bottom, 12)
    }

    private var scopeChip: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(palette.accent)
                    .frame(width: 6, height: 6)
                Text(scopeLabel)
                    .font(.atMono(11, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(palette.mute)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(palette.surface)
                    .overlay(Capsule().stroke(palette.line, lineWidth: 0.5))
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }

    private var scopeLabel: String {
        let count = meetings.count
        if count == 0 { return "Scope: No meetings yet" }
        return "Scope: All meetings · \(count) indexed"
    }

    // MARK: - Body

    @ViewBuilder
    private func bodyArea(ctx: QAContext) -> some View {
        if shouldShowIdleSplash(ctx: ctx) {
            idleBlock
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            conversation(ctx: ctx)
        }
    }

    private func shouldShowIdleSplash(ctx: QAContext) -> Bool {
        messages.isEmpty && !holding && ctx.orchestrator.stage == .idle && ctx.orchestrator.liveAnswer.isEmpty
    }

    private var idleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            QSTitle(
                text: "Hold the dot.\nAsk across every meeting.",
                size: 30,
                tracking: -1,
                color: palette.ink
            )
            .padding(.bottom, 18)
            QSBody(
                text: "Your question never leaves the device. Your answer is synthesized from every transcript on this phone.",
                size: 14,
                color: palette.mute
            )
            .padding(.bottom, 28)
            QSEyebrow("Try asking", color: palette.faint)
                .padding(.bottom, 12)
            ForEach(Array(exemplarQuestions.enumerated()), id: \.offset) { idx, q in
                exemplarRow(q, divider: idx > 0)
            }
            Spacer(minLength: 0)
        }
    }

    private let exemplarQuestions: [String] = [
        "What has Sara committed to overall?",
        "Which decisions are still unresolved?",
        "Who has open action items in the past month?",
    ]

    private func exemplarRow(_ q: String, divider: Bool) -> some View {
        VStack(spacing: 0) {
            if divider { QSDivider() }
            Text("\u{201C}\(q)\u{201D}")
                .font(.atSerif(14.5, weight: .regular))
                .italic()
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        }
    }

    private func conversation(ctx: QAContext) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(messages) { msg in
                        CrossMeetingBlock(
                            message: msg,
                            titlesById: titlesById,
                            orchestrator: ctx.orchestrator
                        )
                        .id(msg.id)
                    }
                    if holding {
                        listeningRow(ctx: ctx)
                            .id("listening")
                    } else if isThinking(ctx: ctx) {
                        thinkingRow
                            .id("thinking")
                    } else if !ctx.orchestrator.liveAnswer.isEmpty {
                        streamingRow(ctx: ctx)
                            .id("streaming")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: holding) { _, on in
                if on { withAnimation { proxy.scrollTo("listening", anchor: .bottom) } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func isThinking(ctx: QAContext) -> Bool {
        switch ctx.orchestrator.stage {
        case .retrieving, .generating:
            return ctx.orchestrator.liveAnswer.isEmpty
        default:
            return false
        }
    }

    private func listeningRow(ctx: QAContext) -> some View {
        VStack(spacing: 16) {
            QSEyebrow("Listening", color: palette.accent)
            ImmersiveWaveform(height: 120, isActive: true)
                .padding(.horizontal, 4)
            Text(liveTranscriptDisplay(ctx: ctx))
                .font(.atSerif(20, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 56)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private func liveTranscriptDisplay(ctx: QAContext) -> String {
        let raw = ctx.questionASR.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "\u{2026}" }
        return "\u{201C}\(raw)\u{201D}"
    }

    private var thinkingRow: some View {
        VStack(spacing: 28) {
            BreathingOrb(done: false)
                .frame(width: 180, height: 180)
            QSEyebrow("Searching \(meetings.count) meetings on device", color: palette.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func streamingRow(ctx: QAContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            QSEyebrow("Answer", color: palette.accent)
            Text(ctx.orchestrator.liveAnswer)
                .font(.atBody(16, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusStrip: some View {
        if let err = lastError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(err)
                    .font(.atMono(10.5, weight: .medium))
                    .tracking(0.2)
                    .foregroundStyle(palette.accent)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        } else if let r = lastResult, let ttfsw = r.ttfswMillis {
            HStack {
                Spacer()
                Text("TTFSW \(Int(ttfsw)) ms · \(r.citations.count) citations")
                    .font(.atMono(10, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(palette.faint)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func bargeInBanner(ctx: QAContext) -> some View {
        if ctx.orchestrator.didBargeIn {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text("You interrupted — keep talking or hold to ask again.")
                    .font(.atMono(10.5, weight: .medium))
                    .tracking(0.2)
                    .foregroundStyle(palette.mute)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(
                palette.surface.opacity(0.9)
                    .overlay(alignment: .top) { QSDivider() }
                    .overlay(alignment: .bottom) { QSDivider() }
            )
            .transition(.opacity)
        }
    }

    // MARK: - Hold FAB

    private func holdFAB(ctx: QAContext) -> some View {
        VStack(spacing: 10) {
            HoldDot(holding: holding)
                .gesture(holdGesture(ctx: ctx))
            Text(holdCaption(ctx: ctx))
                .font(.atMono(11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(palette.faint)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 36)
    }

    private func holdCaption(ctx: QAContext) -> String {
        if holding { return "Release when done" }
        switch ctx.orchestrator.stage {
        case .retrieving:
            return "Searching every meeting"
        case .generating:
            return ctx.orchestrator.liveAnswer.isEmpty ? "Searching every meeting" : "Speaking"
        case .speaking:
            return "Speaking"
        default:
            return messages.isEmpty ? "Hold to ask · across all" : "Hold to ask again"
        }
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

    // MARK: - Logic (preserved)

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
        // Cancel any auto-rearm window that was reopening the mic after a
        // prior barge-in. Without this, the user grabbing the button mid
        // listen-window double-fires QuestionASR.start.
        autoRearmTask?.cancel()
        autoRearmTask = nil
        ctx.orchestrator.clearBargeIn()
        await ctx.orchestrator.cancel()
        do {
            try await ctx.questionASR.start()
        } catch {
            holding = false
            lastError = "\(error)"
        }
    }

    /// Mirrors `ChatThreadView.autoRearmListen` — same 6 s window, same
    /// finalize path through `endHold`. Only difference is the question
    /// routes through `askGlobal` rather than `ask(in: meeting)`.
    private func autoRearmListen(ctx: QAContext) async {
        autoRearmTask?.cancel()
        let task = Task { @MainActor in
            holding = true
            do {
                try await ctx.questionASR.start()
            } catch {
                holding = false
                lastError = "auto-rearm: \(error)"
                return
            }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            if Task.isCancelled { return }
            holding = false
            // Substantive-speech gate — see ChatThreadView.autoRearmListen
            // for the rationale. False barge-ins (cough, AirPods click,
            // Kokoro tail bleed past AEC) used to auto-fire a junk question
            // built from 6 s of room noise; we now require ≥ 2 tokens AND
            // ≥ 8 chars before committing.
            let heard = ctx.questionASR.liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tokenCount = heard.split { $0.isWhitespace }.count
            if tokenCount >= 2 && heard.count >= 8 {
                await endHold(ctx: ctx)
            } else {
                _ = await ctx.questionASR.stop()
            }
        }
        autoRearmTask = task
        await task.value
        autoRearmTask = nil
    }

    private func endHold(ctx: QAContext) async {
        if asking { return }
        asking = true
        defer { asking = false }

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

// MARK: - HoldDot

/// Same Quiet Studio FAB as ChatThreadView. Duplicated as private to avoid
/// cross-file private symbol leakage; the visual contract is small enough
/// that two copies are simpler than promoting it to a shared primitive.
private struct HoldDot: View {
    let holding: Bool
    @Environment(\.atPalette) private var palette

    var body: some View {
        ZStack {
            if holding {
                Circle()
                    .fill(palette.accent.opacity(0.13))
                    .frame(width: 110, height: 110)
                Circle()
                    .stroke(palette.accent.opacity(0.30), lineWidth: 1)
                    .frame(width: 110, height: 110)
            }
            Circle()
                .fill(holding ? palette.accent : palette.ink)
                .frame(width: 76, height: 76)
                .shadow(color: (holding ? palette.accent : Color.black).opacity(0.22),
                        radius: 14, x: 0, y: 12)
            Image(systemName: "mic.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(palette.bg)
        }
        .frame(width: 110, height: 110)
        .scaleEffect(holding ? 1.06 : 1.0)
        .animation(AT.Motion.hold, value: holding)
        .contentShape(Circle())
    }
}

// MARK: - CrossMeetingBlock

/// Editorial answer block for the global chat. Same skeleton as
/// `MessageBlock` in ChatThreadView, but each citation row leads with the
/// source meeting title (resolved through `titlesById`) so the answer feels
/// like it's quoting different meetings, not flattening them.
private struct CrossMeetingBlock: View {
    let message: ChatMessage
    let titlesById: [UUID: String]
    let orchestrator: QAOrchestrator
    @Environment(\.atPalette) private var palette

    var body: some View {
        if message.role == "user" {
            VStack(alignment: .leading, spacing: 8) {
                QSEyebrow("Asked", color: palette.faint)
                Text("\u{201C}\(message.text)\u{201D}")
                    .font(.atSerif(19, weight: .regular))
                    .italic()
                    .lineSpacing(4)
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        QSEyebrow("Answer", color: palette.accent)
                        Spacer()
                        replayButton
                    }
                    Text(message.text)
                        .font(.atBody(16.5, weight: .regular))
                        .lineSpacing(5)
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.citations.isEmpty {
                    citationsBlock
                }
            }
        }
    }

    private var replayButton: some View {
        Button {
            Task { await orchestrator.replay(message.text) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Replay")
                    .font(.atMono(10.5, weight: .semibold))
                    .tracking(0.4)
            }
            .foregroundStyle(palette.mute)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(palette.surface)
                    .overlay(Capsule().stroke(palette.line, lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
    }

    private var citationsBlock: some View {
        // Collapse multiple hits from the same meeting into a single row so
        // a 6-chunk answer that came from one meeting doesn't render six
        // identical rows. Order preserved from the relevance-sorted array.
        let unique = uniqueByMeeting(message.citations)
        return VStack(alignment: .leading, spacing: 0) {
            QSEyebrow("Drawn from", color: palette.faint)
                .padding(.bottom, 12)
            ForEach(Array(unique.prefix(4).enumerated()), id: \.offset) { idx, c in
                citationRow(c, divider: idx > 0)
            }
            if unique.count > 4 {
                Text("+\(unique.count - 4) more")
                    .font(.atMono(10, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(palette.faint)
                    .padding(.top, 8)
            }
        }
    }

    private func citationRow(_ c: ChunkCitation, divider: Bool) -> some View {
        VStack(spacing: 0) {
            if divider { QSDivider() }
            HStack(alignment: .top, spacing: 12) {
                Text(timestamp(c.startSec))
                    .font(.atMono(10, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(palette.accent)
                    .frame(minWidth: 36, alignment: .leading)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meetingTitle(for: c).uppercased())
                        .font(.atMono(10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(palette.mute)
                        .lineLimit(1)
                    if let speaker = c.speakerName, !speaker.isEmpty {
                        Text(speaker)
                            .font(.atBody(13, weight: .regular))
                            .foregroundStyle(palette.mute)
                    }
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.faint)
                    .padding(.top, 4)
            }
            .padding(.vertical, 12)
        }
    }

    private func meetingTitle(for c: ChunkCitation) -> String {
        // 28-char clip keeps the row legible at iPhone widths even at full
        // inset. Topic-derived titles average 18-22 chars after the auto-
        // title pass, so this rarely truncates real titles — only legacy
        // fragment titles that pre-date topic-rename get clipped.
        titlesById[c.meetingId].map { String($0.prefix(36)) } ?? "Unknown meeting"
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
