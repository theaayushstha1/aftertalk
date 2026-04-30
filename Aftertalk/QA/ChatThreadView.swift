import SwiftData
import SwiftUI

/// Quiet Studio "Ask" surface. Hold the dot, ask a question, get a spoken
/// answer back. Visual language is editorial — palette.bg + hairline 0.5pt
/// dividers, no card chrome. The four phases (idle → listening → thinking →
/// answer) come straight from `qs-ask.jsx`; thinking reuses the same
/// `BreathingOrb` the post-recording ProcessingView uses, so there's a single
/// "the device is computing" visual across the app.
struct ChatThreadView: View {
    let meeting: Meeting
    let orchestrator: QAOrchestrator
    let questionASR: QuestionASR
    let repository: MeetingsRepository
    /// `false` when `NLContextualEmbedding` couldn't load — semantic
    /// retrieval would return zero hits and the user would just hear the
    /// grounding-gate disclaimer. The view shows a banner + disables the
    /// hold-to-ask FAB so the failure mode is explained, not silent.
    let semanticQAAvailable: Bool
    /// Invoked when the user taps a citation. The host view dismisses this
    /// sheet, switches the meeting detail to the transcript tab, and scrolls
    /// to `chunkId`. `nil` when the host doesn't support transcript jumping
    /// (e.g. cross-meeting global chat scopes).
    var onJumpToTranscript: ((UUID) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.atPalette) private var palette

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
    /// Captured at the end of `endHold` so the listening row can keep
    /// rendering the user's question while the persist + ask pipeline runs.
    /// Live mid-hold display reads `questionASR.liveTranscript` directly via
    /// the `@Observable` macro on `QuestionASR` — that's what makes the words
    /// stream as the user speaks.
    @State private var finalQuestionText = ""
    @State private var typedQuestion = ""
    @FocusState private var typedQuestionFocused: Bool

    init(meeting: Meeting,
         orchestrator: QAOrchestrator,
         questionASR: QuestionASR,
         repository: MeetingsRepository,
         semanticQAAvailable: Bool = true,
         onJumpToTranscript: ((UUID) -> Void)? = nil) {
        self.meeting = meeting
        self.orchestrator = orchestrator
        self.questionASR = questionASR
        self.repository = repository
        self.semanticQAAvailable = semanticQAAvailable
        self.onJumpToTranscript = onJumpToTranscript
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
            header
            scopeChip
            if !semanticQAAvailable {
                degradedQABanner
            }
            bodyArea
            statusStrip
            bargeInBanner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.bg.ignoresSafeArea())
        // Pin the ask dock as a bottom safe-area inset rather than a regular
        // VStack child. SwiftUI grows the keyboard inset in lockstep with
        // safe-area insets, so the dock now slides up cleanly when the
        // keyboard appears. As a child of the parent VStack with a
        // `.ignoresSafeArea()` background it just sat there.
        .safeAreaInset(edge: .bottom, spacing: 0) { askDock }
        .navigationBarBackButtonHidden(true)
        .atTheme()
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
            finalQuestionText = ""
            Task { await orchestrator.cancel() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Done")
                        .font(.atBody(13, weight: .medium))
                }
                .foregroundStyle(palette.mute)
            }
            .buttonStyle(.plain)
            Spacer()
            QSPrivacyBadge(compact: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, AT.Space.safeTop)
        .padding(.bottom, 14)
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
        let title = meeting.title.uppercased()
        let count = meeting.chunks.count
        let core = count > 0 ? "Scope: \(title) · \(count) indexed"
                             : "Scope: \(title)"
        return core
    }

    // MARK: - Phase-aware body

    @ViewBuilder
    private var bodyArea: some View {
        if shouldShowIdleSplash {
            idleBlock
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            conversation
        }
    }

    private var shouldShowIdleSplash: Bool {
        messages.isEmpty && !holding && orchestrator.stage == .idle && orchestrator.liveAnswer.isEmpty
    }

    private var idleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            QSTitle(
                text: "Hold the dot.\nAsk anything.",
                size: 32,
                tracking: -1.1,
                color: palette.ink
            )
            .padding(.bottom, 18)
            QSBody(
                text: "Your question never leaves the device. Your answer comes from this meeting and the ones around it.",
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
        "What did we decide on the timeline?",
        "Who has open action items?",
        "What's still unresolved from this meeting?",
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

    // MARK: - Conversation (listening + thinking + messages)

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(messages) { msg in
                        MessageBlock(message: msg, orchestrator: orchestrator, onJumpToTranscript: onJumpToTranscript)
                            .id(msg.id)
                    }
                    if holding {
                        listeningRow
                            .id("listening")
                    } else if isThinking {
                        thinkingRow
                            .id("thinking")
                    } else if !orchestrator.liveAnswer.isEmpty {
                        streamingRow
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

    private var isThinking: Bool {
        switch orchestrator.stage {
        case .retrieving, .generating:
            return orchestrator.liveAnswer.isEmpty
        default:
            return false
        }
    }

    private var listeningRow: some View {
        VStack(spacing: 16) {
            QSEyebrow("Listening", color: palette.accent)
            ATListeningDots(color: palette.accent)
                .frame(height: 28)
                .frame(maxWidth: .infinity)
            Text(liveTranscriptDisplay)
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

    private var liveTranscriptDisplay: String {
        // Prefer the live ASR transcript while we're still listening so the
        // words stream into the chat as the user speaks. Once `endHold` runs
        // we capture the final text into `finalQuestionText` so the row keeps
        // rendering the question while the persist + ask pipeline finishes.
        let live = questionASR.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinned = finalQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = !live.isEmpty ? live : pinned
        if raw.isEmpty { return "\u{2026}" }
        return "\u{201C}\(raw)\u{201D}"
    }

    private var thinkingRow: some View {
        VStack(spacing: 28) {
            BreathingOrb(done: false)
                .frame(width: 180, height: 180)
            QSEyebrow("Searching this meeting on device", color: palette.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var streamingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            QSEyebrow("Answer", color: palette.accent)
            Text(orchestrator.liveAnswer)
                .font(.atBody(16, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Status / barge-in

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
                Text("TTFSW \(Int(ttfsw)) ms · total \(Int(r.totalMillis)) ms")
                    .font(.atMono(10, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(palette.faint)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
    }

    /// Shown after the user's voice trips the barge-in energy gate during TTS
    /// playback. Auto-rearm makes this banner short-lived in practice — it
    /// shows during the ~6 s listen window and disappears when the
    /// Banner shown when `NLContextualEmbedding` failed to load. The
    /// recording / summary / transcript paths still work; this view
    /// explains why hold-to-ask is disabled instead of letting the user
    /// hold and get a generic disclaimer for every question.
    private var degradedQABanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.faint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Semantic Q&A unavailable")
                    .font(.atBody(12.5, weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text("Apple's contextual embedding asset hasn't loaded on this device. Recording and summary still work; restart the app or briefly connect to network so iOS can fetch the asset.")
                    .font(.atBody(11.5))
                    .foregroundStyle(palette.mute)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            palette.surface
                .overlay(alignment: .bottom) { QSDivider() }
        )
    }

    /// orchestrator's next `runAsk` resets `didBargeIn`.
    @ViewBuilder
    private var bargeInBanner: some View {
        if orchestrator.didBargeIn {
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

    // MARK: - Ask Dock

    private var askDock: some View {
        VStack(spacing: 6) {
            // Single iMessage-style row: text field stretches the full width,
            // hold-mic + send button live inside the same capsule. Everything
            // is one input affordance — type or hold, your choice.
            HStack(alignment: .center, spacing: 10) {
                // Single-line TextField. With `axis: .vertical` Return
                // inserted a newline rather than firing `onSubmit`, which is
                // why typing Enter looked like a no-op. Single-line gives us
                // back the .send keyboard return, and that's the only path
                // we need: the Q&A pipeline doesn't care about line breaks.
                TextField(
                    semanticQAAvailable ? "Aftertalk" : "Q&A unavailable",
                    text: $typedQuestion
                )
                .font(.atBody(15))
                .foregroundStyle(palette.ink)
                .focused($typedQuestionFocused)
                .submitLabel(.send)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .disabled(!semanticQAAvailable || asking || holding)
                .onSubmit {
                    Task { await submitTypedQuestion() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canSubmitTypedQuestion {
                    sendButton
                } else {
                    inlineHoldDot
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 56)
            .background(
                Capsule(style: .continuous)
                    .fill(palette.surface)
                    .overlay(Capsule(style: .continuous).stroke(palette.line, lineWidth: 0.5))
            )

            // Caption sits under the row so the user always knows what state
            // the mic is in (Hold to ask / Release / Speaking …) without
            // taking another row of vertical space.
            Text(holdCaption)
                .font(.atMono(10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(palette.faint)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .background(
            Rectangle()
                .fill(palette.bg.opacity(0.96))
                .overlay(alignment: .top) { QSDivider() }
        )
    }

    /// Compact mic glyph that sits inside the input capsule when the text
    /// field is empty — visual analogue of the iMessage waveform glyph. Same
    /// `holdGesture` as the original FAB so behaviour is identical: press to
    /// open ASR, release to fire the question. Color shifts to `accent` while
    /// held so the user gets immediate feedback.
    private var inlineHoldDot: some View {
        ZStack {
            // Solid filled circle behind the glyph so the mic always reads on
            // the cream capsule background. We previously used a subtle
            // `.symbolRenderingMode(.hierarchical)` over `palette.mute` which
            // rendered as effectively invisible on cream — see screenshot
            // 2026-04-30 at 7.48.57 AM. Now: ink-filled circle by default,
            // accent-filled when held, with a soft halo under the press.
            if holding {
                Circle()
                    .fill(palette.accent.opacity(0.18))
                    .frame(width: 44, height: 44)
            }
            Circle()
                .fill(holding ? palette.accent : palette.ink)
                .frame(width: 36, height: 36)
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.bg)
        }
        .frame(width: 46, height: 46)
        .contentShape(Circle())
        .gesture(holdGesture)
        .opacity(semanticQAAvailable ? 1.0 : 0.35)
        .allowsHitTesting(semanticQAAvailable)
        .accessibilityLabel("Hold to ask")
    }

    private var sendButton: some View {
        Button {
            Task { await submitTypedQuestion() }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send question")
    }

    private var typedQuestionTrimmed: String {
        typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitTypedQuestion: Bool {
        semanticQAAvailable && !asking && !holding && !typedQuestionTrimmed.isEmpty
    }

    private var holdCaption: String {
        if holding { return "Release when done" }
        switch orchestrator.stage {
        case .retrieving:
            return "Thinking on device"
        case .generating:
            return orchestrator.liveAnswer.isEmpty ? "Thinking on device" : "Speaking"
        case .speaking:
            return "Speaking"
        default:
            return messages.isEmpty ? "Hold to ask" : "Hold to ask again"
        }
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

    // MARK: - Logic (unchanged)

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
        finalQuestionText = ""
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
    /// the window by routing through `endHold` — same persist + ask pipeline
    /// as a manual release.
    private func autoRearmListen() async {
        autoRearmTask?.cancel()
        let task = Task { @MainActor in
            holding = true
            finalQuestionText = ""
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
                finalQuestionText = ""
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

        // Capture the mic-release timestamp BEFORE `stop()` runs its silence
        // pad + final-delta wait. That's the honest TTFSW reference point —
        // measuring from after stop() returns would silently exclude the
        // ~600 ms of trailing-silence pad we deliberately added.
        let releasedAt = ContinuousClock.now
        let question = await questionASR.stop()
        finalQuestionText = question
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finalQuestionText = ""
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
        let result = await orchestrator.ask(question: question, in: meeting, releasedAt: releasedAt)
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

    private func submitTypedQuestion() async {
        let question = typedQuestionTrimmed
        guard canSubmitTypedQuestion, !question.isEmpty else { return }

        typedQuestion = ""
        typedQuestionFocused = false
        finalQuestionText = ""
        autoRearmTask?.cancel()
        autoRearmTask = nil
        orchestrator.clearBargeIn()
        await orchestrator.cancel()

        asking = true
        defer { asking = false }

        if threadId == nil {
            await ensureThread()
        }
        guard let threadId else {
            lastError = "thread not ready"
            typedQuestion = question
            return
        }

        let sentAt = ContinuousClock.now
        do {
            try await repository.appendChatMessage(threadId: threadId, role: "user", text: question)
        } catch {
            lastError = "save question: \(error)"
            typedQuestion = question
            return
        }

        let result = await orchestrator.ask(question: question, in: meeting, releasedAt: sentAt)
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

// MARK: - HoldDot

/// Quiet Studio Q&A FAB. 76pt core. Idle = ink fill + mic glyph. Holding =
/// accent fill + soft halo + scale 1→1.08. Mirrors the JSX `qs-ask` button
/// exactly so the muscle memory between recording (`RecordButton`) and asking
/// is identical.
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

// MARK: - MessageBlock

/// Editorial message rendering — no chat bubbles. User questions render as a
/// serif italic "Asked …" block; assistant answers render as body copy with
/// a "Drawn from" citations row, matching the answer phase in `qs-ask.jsx`.
private struct MessageBlock: View {
    let message: ChatMessage
    let orchestrator: QAOrchestrator
    var onJumpToTranscript: ((UUID) -> Void)? = nil
    @Environment(\.atPalette) private var palette

    var body: some View {
        if message.role == "user" {
            VStack(alignment: .leading, spacing: 8) {
                QSEyebrow("Asked", color: palette.faint)
                Text("\u{201C}\(message.text)\u{201D}")
                    .font(.atSerif(19, weight: .medium))
                    .italic()
                    .lineSpacing(4)
                    .foregroundColor(palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(palette.ink)
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
        VStack(alignment: .leading, spacing: 0) {
            QSEyebrow("Drawn from", color: palette.faint)
                .padding(.bottom, 12)
            ForEach(Array(message.citations.prefix(4).enumerated()), id: \.offset) { idx, c in
                citationRow(c, divider: idx > 0)
            }
        }
    }

    private func citationRow(_ c: ChunkCitation, divider: Bool) -> some View {
        Button {
            onJumpToTranscript?(c.chunkId)
        } label: {
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
                        if let speaker = c.speakerName, !speaker.isEmpty {
                            Text(speaker.uppercased())
                                .font(.atMono(10, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(palette.mute)
                        }
                        Text("\(timestamp(c.startSec))–\(timestamp(c.endSec))")
                            .font(.atBody(13, weight: .regular))
                            .foregroundStyle(palette.mute)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(onJumpToTranscript == nil ? palette.faint : palette.accent)
                        .padding(.top, 4)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .disabled(onJumpToTranscript == nil)
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
