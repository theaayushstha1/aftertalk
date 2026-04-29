import SwiftUI

/// Quiet Studio detail screen. Editorial hero (eyebrow + 36pt title +
/// stacked-avatar speaker row + meta tags), then a hairline tab strip with
/// `summary / transcript / actions`. The "Ask this meeting" pill floats at
/// the bottom-right of the summary tab — never modal, never sticky on the
/// transcript or actions tabs.
struct MeetingDetailView: View {
    let meeting: Meeting
    let qaContext: QAContext?
    let pipeline: MeetingProcessingPipeline?
    @Environment(\.atPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .summary
    @State private var openAsk = false
    /// Set by ChatThreadView's citation tap callback. Consumed by the
    /// ScrollViewReader in `transcriptTab` to scroll the matching chunk
    /// into view on tab switch.
    @State private var pendingScrollChunkId: UUID? = nil
    /// Chunk currently highlighted from a citation jump. Cleared after a
    /// short visual pulse so the row briefly reads as "this is the source".
    @State private var highlightedChunkId: UUID? = nil
    /// Tracks an in-flight reprocess. Disables the button so a double-tap
    /// can't enqueue a second pipeline run while the first is still tearing
    /// down + re-running ASR / diarization / chunking.
    @State private var reprocessing = false
    @State private var reprocessError: String?

    enum Tab: String, CaseIterable, Identifiable {
        case summary, transcript, actions
        var id: String { rawValue }
        var label: String {
            switch self {
            case .summary: "Summary"
            case .transcript: "Transcript"
            case .actions: "Actions"
            }
        }
    }

    init(
        meeting: Meeting,
        qaContext: QAContext? = nil,
        pipeline: MeetingProcessingPipeline? = nil,
        initialScrollChunkId: UUID? = nil
    ) {
        self.meeting = meeting
        self.qaContext = qaContext
        self.pipeline = pipeline
        self.initialScrollChunkId = initialScrollChunkId
    }

    private let initialScrollChunkId: UUID?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            palette.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    hero
                    tabStrip
                    Group {
                        switch selectedTab {
                        case .summary: summaryTab
                        case .transcript: transcriptTab
                        case .actions: actionsTab
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 140)
                }
            }
            if selectedTab == .summary, qaContext != nil {
                askButton
                    .padding(.trailing, 20)
                    // The tab bar's record FAB lifts ~52pt above the bar's top
                    // edge. The reserved safeAreaInset under us is only the bar
                    // height — the FAB draws *outside* that frame, so a small
                    // bottom padding here would visually collide with the FAB
                    // (the user sees a dark pill merging with the dark FAB).
                    // Lift well past the FAB tip so the pill reads as a
                    // distinct floating CTA above the tab strip.
                    .padding(.bottom, 88)
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $openAsk) {
            // fullScreenCover sidesteps the SwiftUI quirk where two
            // .navigationDestination modifiers on the same NavigationStack
            // (the parent's `for: UUID.self` plus this isPresented one)
            // race and the second never fires. The Q&A loop wants the whole
            // viewport anyway.
            NavigationStack { askDestination }
        }
        .onDisappear {
            // Real teardown: when the user pops back to the meetings list,
            // cancel any ongoing Q&A, drop Kokoro's ~300 MB CoreML graphs,
            // and deactivate the .playAndRecord session so the mic indicator
            // clears. Tab-switching inside this view does NOT deactivate (see
            // ChatThreadView.onDisappear). Order: stop work → cleanup TTS →
            // deactivate; flipping the last two deadlocks on "deactivate while
            // I/O running."
            if let ctx = qaContext {
                Task {
                    await ctx.orchestrator.cancel()
                    await ctx.orchestrator.cleanupTTS()
                    await AudioSessionManager.shared.deactivate()
                }
            }
        }
        .atTheme()
        .task {
            if let target = initialScrollChunkId, pendingScrollChunkId == nil {
                selectedTab = .transcript
                pendingScrollChunkId = target
            }
        }
        .alert(
            "Repair failed",
            isPresented: Binding(
                get: { reprocessError != nil },
                set: { if !$0 { reprocessError = nil } }
            ),
            presenting: reprocessError
        ) { _ in
            Button("OK", role: .cancel) { reprocessError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
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
            Spacer()
            if canReprocess {
                reprocessButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, AT.Space.safeTop)
        .padding(.bottom, 12)
    }

    /// Show the button whenever the pipeline is wired. We used to also gate
    /// on `meeting.audioFileURL` + file-on-disk, but that hid the affordance
    /// on meetings whose URL didn't persist correctly through SwiftData,
    /// leaving the user with no way to retry. The reprocess attempt itself
    /// surfaces a clear "audio missing" alert when the file isn't reachable,
    /// which is far better UX than a silently-absent button.
    private var canReprocess: Bool {
        pipeline != nil
    }

    private var reprocessButton: some View {
        Button {
            Task { await runReprocess() }
        } label: {
            HStack(spacing: 6) {
                if reprocessing {
                    ProgressView().controlSize(.mini).tint(palette.bg)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(reprocessing ? "Repairing…" : "Repair")
                    .font(.atMono(11.5, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
            }
            .foregroundStyle(palette.bg)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(palette.accent)
            )
        }
        .buttonStyle(.plain)
        .disabled(reprocessing)
    }

    private func runReprocess() async {
        guard let pipeline, !reprocessing else { return }
        // Surface a clearer error when the saved WAV is gone before we even
        // start tearing down chunks — otherwise the user sees a generic
        // "couldn't re-run" message and assumes the whole feature is broken.
        let audioMissing: Bool = {
            guard let url = meeting.audioFileURL else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }()
        if audioMissing {
            reprocessError = "Audio file for this meeting isn't on disk anymore, so speakers can't be re-detected. Re-record the conversation to rerun diarization with the latest thresholds."
            return
        }
        reprocessing = true
        let ok = await pipeline.reprocess(meetingId: meeting.id)
        reprocessing = false
        if !ok {
            reprocessError = "Couldn't re-run the pipeline. Check the Xcode console for the failure reason — most often the diarization model failed to load."
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            QSEyebrow("\(dateLabel) · \(durationLabel)", color: palette.faint)
                .padding(.bottom, 12)
            QSTitle(text: meeting.title, size: 36, tracking: -1.3, color: palette.ink)
                .padding(.bottom, 18)
            speakerRow
                .padding(.bottom, 18)
            tagRow
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    private var speakerRow: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: -8) {
                ForEach(Array(speakerNames.prefix(4).enumerated()), id: \.offset) { idx, name in
                    avatar(initials: initials(for: name), idx: idx)
                }
            }
            if !speakerNames.isEmpty {
                Text(speakerNames.joined(separator: " · "))
                    .font(.atBody(12, weight: .regular))
                    .foregroundStyle(palette.mute)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Speaker labels pending")
                    .font(.atBody(12))
                    .foregroundStyle(palette.faint)
            }
            Spacer(minLength: 0)
        }
    }

    private func avatar(initials: String, idx: Int) -> some View {
        let palette = avatarPalette[idx % avatarPalette.count]
        return Text(initials)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(palette))
            .overlay(Circle().stroke(self.palette.bg, lineWidth: 2))
    }

    private var tagRow: some View {
        let tags = computedTags
        return Group {
            if tags.isEmpty {
                EmptyView()
            } else {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        Text(t.uppercased())
                            .font(.atMono(10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(palette.faint)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .overlay(
                                Capsule().stroke(palette.line, lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { t in
                tabButton(t)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { QSDivider() }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private func tabButton(_ t: Tab) -> some View {
        let active = t == selectedTab
        Button {
            withAnimation(AT.Motion.standard) { selectedTab = t }
        } label: {
            HStack(spacing: 6) {
                Text(t.label)
                    .font(.atBody(13, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(active ? palette.ink : palette.faint)
                if t == .actions, actionCount > 0 {
                    Text("\(actionCount)")
                        .font(.atMono(10, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(.vertical, 11)
            .padding(.trailing, 22)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? palette.ink : Color.clear)
                    .frame(height: 1.5)
                    .offset(y: 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary tab

    @ViewBuilder
    private var summaryTab: some View {
        if let s = meeting.summary {
            VStack(alignment: .leading, spacing: 0) {
                if let lead = leadSentence(from: s) {
                    QSEyebrow("The shape of it", color: palette.faint)
                        .padding(.bottom, 10)
                    Text(lead)
                        .font(.atDisplay(22, weight: .regular))
                        .tracking(-0.4)
                        .lineSpacing(6)
                        .foregroundStyle(palette.ink)
                        .padding(.bottom, 28)
                }
                if !s.decisions.isEmpty {
                    decisionsBlock(s.decisions)
                        .padding(.bottom, 28)
                }
                if let quote = quotedMoment {
                    quoteBlock(quote)
                        .padding(.bottom, 28)
                }
                if !s.topics.isEmpty {
                    listBlock(title: "Topics", items: s.topics, mono: true)
                        .padding(.bottom, 28)
                }
                if !s.openQuestions.isEmpty {
                    listBlock(title: "Open questions", items: s.openQuestions, mono: false)
                        .padding(.bottom, 28)
                }
                generatedFooter(s)
            }
        } else {
            unavailable(
                title: "Summary not generated yet",
                body: "Foundation Models was unavailable, or the recording was too short to distill."
            )
        }
    }

    private func decisionsBlock(_ decisions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            QSEyebrow("Decisions · \(String(format: "%02d", decisions.count))", color: palette.faint)
                .padding(.bottom, 12)
            ForEach(Array(decisions.enumerated()), id: \.offset) { idx, d in
                HStack(alignment: .top, spacing: 14) {
                    Text(String(format: "%02d", idx + 1))
                        .font(.atMono(11, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(palette.accent)
                        .frame(minWidth: 22, alignment: .leading)
                        .padding(.top, 2)
                    Text(d)
                        .font(.atBody(15))
                        .lineSpacing(5)
                        .foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                .overlay(alignment: .top) {
                    if idx > 0 { QSDivider() }
                }
            }
        }
    }

    private func quoteBlock(_ q: QuotedMoment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            QSEyebrow("Quoted moments", color: palette.faint)
                .padding(.bottom, 4)
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(palette.accent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    Text("\u{201C}\(q.text)\u{201D}")
                        .font(.atSerif(18))
                        .italic()
                        .lineSpacing(5)
                        .tracking(-0.2)
                        .foregroundStyle(palette.ink)
                    Text("\(q.speaker.uppercased()) · \(q.time)")
                        .font(.atMono(11, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(palette.faint)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    palette.surface
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: AT.Radius.base * 1.2,
                                topTrailingRadius: AT.Radius.base * 1.2,
                                style: .continuous
                            )
                        )
                )
            }
        }
    }

    private func listBlock(title: String, items: [String], mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            QSEyebrow(title, color: palette.faint)
                .padding(.bottom, 10)
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(palette.faint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 8)
                    Text(item)
                        .font(.atBody(14.5))
                        .lineSpacing(4)
                        .foregroundStyle(palette.mute)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    if idx > 0 { QSDivider() }
                }
            }
        }
    }

    private func generatedFooter(_ s: MeetingSummaryRecord) -> some View {
        Text("Distilled in \(Int(s.generationLatencyMillis)) ms · \(s.generatedAt.formatted(.dateTime.hour().minute()))")
            .font(.atMono(10, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(palette.faint)
    }

    // MARK: - Transcript tab

    @ViewBuilder
    private var transcriptTab: some View {
        if !chunks.isEmpty {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    QSEyebrow("Full transcript · \(chunks.count) turns", color: palette.faint)
                        .padding(.bottom, 16)
                    ForEach(chunks) { c in
                        transcriptRow(c)
                            .id(c.id)
                    }
                }
                .onChange(of: pendingScrollChunkId) { _, newValue in
                    guard let target = newValue else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    highlightedChunkId = target
                    pendingScrollChunkId = nil
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        await MainActor.run {
                            if highlightedChunkId == target {
                                highlightedChunkId = nil
                            }
                        }
                    }
                }
            }
        } else if !meeting.fullTranscript.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                QSEyebrow("Full transcript", color: palette.faint)
                Text(meeting.fullTranscript)
                    .font(.atBody(14.5))
                    .lineSpacing(5)
                    .foregroundStyle(palette.ink)
            }
        } else {
            unavailable(
                title: "No transcript captured",
                body: "ASR didn't see any speech, or the recording was too short to chunk."
            )
        }
    }

    private func transcriptRow(_ c: TranscriptChunk) -> some View {
        let isHighlighted = highlightedChunkId == c.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(speakerLabel(for: c).uppercased())
                    .font(.atMono(10.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(isHighlighted ? palette.accent : palette.mute)
                Text(formatTimecode(c.startSec))
                    .font(.atMono(10, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(palette.faint)
            }
            Text(c.text)
                .font(.atBody(14.5))
                .lineSpacing(5)
                .foregroundStyle(palette.ink)
        }
        .padding(.vertical, isHighlighted ? 12 : 9)
        .padding(.horizontal, isHighlighted ? 12 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.surface)
                .opacity(isHighlighted ? 1 : 0)
        )
        .padding(.bottom, isHighlighted ? 12 : 9)
        .animation(.easeInOut(duration: 0.25), value: isHighlighted)
    }

    // MARK: - Actions tab

    @ViewBuilder
    private var actionsTab: some View {
        if let s = meeting.summary, !s.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                QSEyebrow("\(s.actionItems.count) action items", color: palette.faint)
                    .padding(.bottom, 14)
                ForEach(Array(s.actionItems.enumerated()), id: \.element.id) { idx, item in
                    actionRow(item, isFirst: idx == 0)
                }
            }
        } else {
            unavailable(
                title: "No action items",
                body: "The summary didn't surface anything assignable. Tap Ask this meeting to dig deeper."
            )
        }
    }

    private func actionRow(_ item: ActionItemRecord, isFirst: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(palette.line, lineWidth: 1.5)
                .frame(width: 22, height: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.description)
                    .font(.atBody(15))
                    .lineSpacing(4)
                    .foregroundStyle(palette.ink)
                if let owner = item.owner, !owner.isEmpty {
                    HStack(spacing: 8) {
                        Text("@\(owner.uppercased())")
                            .font(.atMono(11, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            if !isFirst { QSDivider() }
        }
    }

    // MARK: - Unavailable

    private func unavailable(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            QSEyebrow(title, color: palette.faint)
            QSBody(text: body, color: palette.mute)
        }
        .padding(.vertical, 32)
    }

    // MARK: - Ask CTA

    private var askButton: some View {
        Button {
            openAsk = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Ask this meeting")
                    .font(.atBody(13, weight: .semibold))
                    .tracking(-0.1)
            }
            .foregroundStyle(palette.bg)
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(
                Capsule()
                    .fill(palette.ink)
                    .overlay(
                        Capsule()
                            .stroke(palette.bg.opacity(0.18), lineWidth: 1)
                    )
            )
            // Soft halo only — heavier `y: 12` shadow read as a second pill
            // shape behind the CTA, which compounded the collision with the
            // tab bar's FAB shadow underneath.
            .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var askDestination: some View {
        if let ctx = qaContext {
            ChatThreadView(
                meeting: meeting,
                orchestrator: ctx.orchestrator,
                questionASR: ctx.questionASR,
                repository: ctx.repository,
                onJumpToTranscript: { chunkId in
                    pendingScrollChunkId = chunkId
                    selectedTab = .transcript
                    openAsk = false
                }
            )
        } else {
            unavailable(
                title: "Ask unavailable",
                body: "The Q&A pipeline failed to initialize. Foundation Models may be unavailable on this device."
            )
        }
    }

    // MARK: - Helpers

    private var avatarPalette: [Color] {
        [Color(hex: 0xC36A47), Color(hex: 0x7A8F66), Color(hex: 0x5C7691), Color(hex: 0xA88B6E)]
    }

    private var speakerNames: [String] {
        let labelled = meeting.speakers
            .sorted { ($0.firstSeenSec ?? .infinity) < ($1.firstSeenSec ?? .infinity) }
            .map(\.displayName)
        if !labelled.isEmpty { return labelled }
        let inferred = Array(Set(chunks.compactMap { $0.speakerName })).sorted()
        return inferred
    }

    private var chunks: [TranscriptChunk] {
        meeting.chunks.sorted { $0.orderIndex < $1.orderIndex }
    }

    private var actionCount: Int {
        meeting.summary?.actionItems.count ?? 0
    }

    private var dateLabel: String {
        meeting.recordedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var durationLabel: String {
        let total = Int(meeting.durationSeconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    private var computedTags: [String] {
        var out: [String] = []
        if let topic = meeting.summary?.topics.first { out.append(topic) }
        if !speakerNames.isEmpty { out.append("\(speakerNames.count) voice\(speakerNames.count == 1 ? "" : "s")") }
        if let s = meeting.summary, !s.actionItems.isEmpty {
            out.append("\(s.actionItems.count) action\(s.actionItems.count == 1 ? "" : "s")")
        }
        return out
    }

    private func leadSentence(from s: MeetingSummaryRecord) -> String? {
        if let d = s.decisions.first { return d }
        if let t = s.topics.first { return t }
        if let a = s.actionItems.first?.description { return a }
        return nil
    }

    private var quotedMoment: QuotedMoment? {
        guard let chunk = chunks.first(where: { !$0.text.isEmpty }) else { return nil }
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let speaker = chunk.speakerName ?? "Voice 1"
        return QuotedMoment(text: text, speaker: speaker, time: formatTimecode(chunk.startSec))
    }

    private func speakerLabel(for c: TranscriptChunk) -> String {
        c.speakerName ?? c.speakerId ?? "Voice"
    }

    private func formatTimecode(_ sec: Double) -> String {
        let total = Int(sec.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first }.map { String($0) }
        return chars.joined().uppercased()
    }
}

private struct QuotedMoment: Hashable {
    let text: String
    let speaker: String
    let time: String
}
