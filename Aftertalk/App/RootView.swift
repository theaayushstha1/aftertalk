import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(PrivacyMonitor.self) private var privacy
    @Environment(\.atPalette) private var palette

    // Injected from AftertalkApp so this VM survives TabView re-renders.
    // It used to be `@State private var recording = RecordingViewModel()`,
    // which tab switches could reset, dropping the AsyncStream consumer
    // tasks while the audio engine kept running.
    let recording: RecordingViewModel
    let perf: SessionPerfSampler
    let interruptions: AudioInterruptionObserver

    @State private var pipeline: MeetingProcessingPipeline?
    @State private var qa: QAContext?
    @State private var debugVisible = false
    @State private var selectedTab: QSTab = .meetings
    /// When the user taps the minimize chevron on the recording surface, we
    /// hide the fullScreenCover but keep the audio engine + ASR streamer
    /// running. They can navigate Meetings/Search/Chat/Settings while a
    /// session is live and tap the floating "RECORDING · 00:23" pill to
    /// expand back to the full waveform/transcript view. Auto-resets to
    /// `false` whenever a recording stops so the next session starts
    /// expanded by default.
    @State private var recordingPanelMinimized = false
    /// Drives the auto-dismissing "Summary ready" ping. Set to a non-nil
    /// stage when the pipeline transitions into a post-recording state; a
    /// 3s Task clears it on `.done`. We only render the toast when this is
    /// non-nil AND `recording.isRecording == false` so a stale `.done` from
    /// the previous session can never paint over a *new* live recording.
    @State private var pipelineToast: ProcessingStage? = nil
    @State private var pipelineToastTask: Task<Void, Never>? = nil

    init(recording: RecordingViewModel, perf: SessionPerfSampler, interruptions: AudioInterruptionObserver) {
        self.recording = recording
        self.perf = perf
        self.interruptions = interruptions
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            tabContent
                .safeAreaInset(edge: .bottom) {
                    // Reserve room so the bar (with FAB lifting +20pt above
                    // it) never overlaps tab content. 64pt bar + 20pt FAB lift.
                    Color.clear.frame(height: QSTabBar.barHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            QSTabBar(
                selection: $selectedTab,
                recording: recording,
                onRecordTap: { Task { await recording.toggle() } }
            )
        }
        .overlay(alignment: .top) {
            if recording.isRecording && recordingPanelMinimized {
                recordingMiniPill
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if !recording.isRecording, let stage = pipelineToast {
                PipelineToastView(stage: stage)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: selectedTab)
        .animation(.easeInOut(duration: 0.22), value: recordingPanelMinimized)
        .animation(.easeInOut(duration: 0.22), value: pipelineToast)
        .task { configurePipeline() }
        .onChange(of: recording.isRecording) { _, isOn in
            if isOn {
                // Stale `.done(...)` from the previous session lingers on
                // `pipeline.stage` until the next `process(...)` overwrites
                // it. Hard-reset both the pipeline stage and the toast so
                // nothing from the prior run paints over a new recording.
                pipeline?.stage = .idle
                pipelineToastTask?.cancel()
                pipelineToast = nil
                recordingPanelMinimized = false
            } else {
                recordingPanelMinimized = false
            }
        }
        .onChange(of: pipelineStageKey) { _, _ in
            handlePipelineStageChange()
        }
        .alert("Microphone access required", isPresented: .constant(recording.permissionDenied)) {
            Button("OK") { recording.permissionDenied = false }
        } message: {
            Text("Aftertalk needs your microphone to record meetings. Audio never leaves your device.")
        }
        .fullScreenCover(isPresented: Binding(
            get: { recording.isRecording && !recordingPanelMinimized },
            // Catches the system-driven dismissal (swipe-down gesture) and
            // converts it into a *minimize* instead of letting SwiftUI flip
            // the binding to false — which we couldn't honor here anyway,
            // because the audio engine is owned by `recording`. We don't
            // want a pull-down to silently kill an in-flight meeting.
            set: { newValue in
                if !newValue && recording.isRecording {
                    recordingPanelMinimized = true
                }
            }
        )) {
            recordingSurface
        }
    }

    // MARK: - Tab routing

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .meetings:
            MeetingsListView(qaContext: qa, pipeline: pipeline)
        case .search:
            SearchView()
        case .chat:
            GlobalChatView(qaContext: qa, pipeline: pipeline)
        case .settings:
            SettingsView(perf: perf)
        }
    }

    // MARK: - Recording surface (presented while live)

    private var recordingSurface: some View {
        ZStack(alignment: .top) {
            palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                recordHeader
                statusEyebrow
                LowBatteryBanner()
                timer
                fragmentLabel
                // Waveform shrunk from 180→120 + trimmed padding to give the
                // live transcript more room. The transcript pane uses
                // `.frame(maxHeight: .infinity)` so the reclaimed space
                // automatically flows there.
                ImmersiveWaveform(height: 120, isActive: recording.isRecording)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                transcriptPane
                RecordButton(isRecording: recording.isRecording) {
                    Task { await recording.toggle() }
                }
                .padding(.bottom, 28)
            }

            if debugVisible {
                DebugOverlay(recording: recording, privacy: privacy)
                    .transition(.opacity)
            }
        }
        .gesture(
            TapGesture(count: 2)
                .simultaneously(with: TapGesture(count: 1))
                .onEnded { _ in
                    withAnimation(.easeInOut(duration: 0.2)) { debugVisible.toggle() }
                }
        )
        .atTheme()
    }

    private var recordHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                recordingPanelMinimized = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.mute)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(palette.surface)
                            .overlay(Circle().stroke(palette.line, lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize recording")
            VStack(alignment: .leading, spacing: 2) {
                QSEyebrow("Aftertalk", color: palette.faint)
                Text("On this device only")
                    .font(.atBody(12))
                    .foregroundStyle(palette.mute)
            }
            Spacer()
            PrivacyBadge(state: privacy.state, compact: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, AT.Space.safeTop)
        .padding(.bottom, 14)
    }

    // MARK: - Minimized recording pill (shown across all tabs while live)

    private var recordingMiniPill: some View {
        Button {
            recordingPanelMinimized = false
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(palette.accent)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle().stroke(palette.accent.opacity(0.18), lineWidth: 4)
                    )
                Text("RECORDING")
                    .font(.atMono(10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(palette.ink)
                Text(elapsedString)
                    .font(.atMono(11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.mute)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(palette.surface)
                    .overlay(Capsule().stroke(palette.line, lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand recording. \(elapsedString) elapsed.")
    }

    private var statusEyebrow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if recording.isRecording, !recording.isInterrupted {
                    Circle()
                        .fill(palette.accent)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle().stroke(palette.accent.opacity(0.18), lineWidth: 4)
                        )
                }
                Text(statusLabel)
                    .font(.atMono(10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(statusColor)
            }
            if recording.isInterrupted, let reason = recording.interruptionReason {
                Text(reason)
                    .font(.atBody(12))
                    .foregroundStyle(palette.mute)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 14)
    }

    private var statusLabel: String {
        if recording.isInterrupted { return "INTERRUPTED · PAUSED" }
        return recording.isRecording ? "RECORDING · LIVE" : "READY · TAP TO BEGIN"
    }

    private var statusColor: Color {
        if recording.isInterrupted { return palette.mute }
        return recording.isRecording ? palette.accent : palette.faint
    }

    private var timer: some View {
        Text(elapsedString)
            .font(.system(size: 64, weight: .light, design: .default))
            .tracking(-3)
            .monospacedDigit()
            .foregroundStyle(palette.ink)
    }

    private var fragmentLabel: some View {
        Text(fragmentText)
            .font(.atMono(11, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(palette.faint)
            .padding(.top, 6)
    }

    private var elapsedString: String {
        let total = Int(recording.elapsedSeconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var fragmentText: String {
        let words = recording.transcript.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        if recording.isRecording {
            return "\(words) word\(words == 1 ? "" : "s") captured · 0 sent"
        }
        return words == 0 ? "Idle" : "\(words) word\(words == 1 ? "" : "s") on file"
    }

    private var transcriptPane: some View {
        // Anchor the bottom of the scrollable content so we can pin the
        // viewport to the latest line as Moonshine emits new text. Without
        // this the user has to manually swipe to catch up to the live edge,
        // which defeats the point of an in-recording live transcript.
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    QSEyebrow("Live transcript", color: palette.faint)
                        .padding(.bottom, 6)
                    if recording.transcript.isEmpty {
                        Text(recording.isRecording ? "Listening…" : "Tap the dot below to start a meeting.")
                            .font(.atBody(14))
                            .foregroundStyle(palette.mute)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Two-tier render. Committed = full ink, weight-stable.
                        // Tentative = dim/italic so the user reads it as "we're
                        // still hearing this, may revise". Same isFinal flag the
                        // Moonshine wrapper already exposes — the grounding-gate
                        // analog for live ASR.
                        //
                        // Built as a single `AttributedString` instead of
                        // `Text + Text + Text` because the operator was
                        // deprecated in iOS 26 in favour of interpolation /
                        // attributed strings. AttributedString preserves
                        // per-segment styling and renders as one inline run.
                        Text(liveTranscriptAttributed)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if recording.isRecording {
                        HStack(spacing: 8) {
                            ATListeningDots(color: palette.faint)
                            Text("listening")
                                .font(.atBody(12))
                                .italic()
                                .foregroundStyle(palette.faint)
                        }
                        .padding(.top, 4)
                    }
                    // Invisible anchor at the very end of the content. We
                    // pin scroll position to this so the live transcript
                    // tail stays in view as new lines arrive.
                    Color.clear
                        .frame(height: 1)
                        .id(transcriptTailAnchor)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)
            // Auto-scroll on every transcript change. We observe
            // `recording.transcript` (the joined committed+tentative view)
            // instead of the two underlying fields independently — a single
            // ASR delta updates both `committedTranscript` and
            // `tentativeTranscript` synchronously inside `apply(delta:)`,
            // so two separate `.onChange` hooks both fired in the same
            // frame and SwiftUI logged
            // "onChange(of: String) action tried to update multiple times
            // per frame." `transcript` is recomputed at the tail of the
            // same `apply(delta:)`, so observing it captures the same
            // intent as one notification per delta.
            .onChange(of: recording.transcript) { _, _ in
                scrollTranscriptToTail(proxy: proxy)
            }
            .onChange(of: recording.isRecording) { _, isOn in
                if isOn { scrollTranscriptToTail(proxy: proxy, animated: false) }
            }
        }
    }

    /// Stable identifier for the trailing anchor view inside `transcriptPane`.
    /// Pulled out as a static so its identity is stable across SwiftUI
    /// re-renders (using a literal in `.id(...)` would still work but having
    /// a named constant makes the wiring obvious).
    private var transcriptTailAnchor: String { "transcript-tail" }

    /// Build the live-transcript display as a single `AttributedString` so
    /// the committed (full-ink) and tentative (dim italic) runs render
    /// inline without using the iOS 26-deprecated `Text + Text + Text`
    /// operator chain.
    private var liveTranscriptAttributed: AttributedString {
        var attributed = AttributedString(recording.committedTranscript)
        attributed.font = .atBody(15)
        attributed.foregroundColor = palette.ink

        let needsSpace =
            !recording.committedTranscript.isEmpty
            && !recording.tentativeTranscript.isEmpty
        if needsSpace {
            attributed.append(AttributedString(" "))
        }

        var tentative = AttributedString(recording.tentativeTranscript)
        tentative.font = .atBody(15).italic()
        tentative.foregroundColor = palette.faint
        attributed.append(tentative)

        return attributed
    }

    private func scrollTranscriptToTail(proxy: ScrollViewProxy, animated: Bool = true) {
        // The user complaint was "I have to swipe to catch up" — the cure is
        // to push the scroll to the bottom anchor on every text mutation.
        // We anchor to `.bottom` so the latest tentative word is exactly at
        // the visible bottom edge, not somewhere mid-pane.
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(transcriptTailAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(transcriptTailAnchor, anchor: .bottom)
        }
    }

    /// Stable key driven by pipeline stage so SwiftUI only re-fires
    /// `onChange` on real transitions (not on every embedding progress tick,
    /// which would otherwise reset the auto-dismiss timer mid-progress).
    private var pipelineStageKey: String {
        guard let stage = pipeline?.stage else { return "nil" }
        switch stage {
        case .idle: return "idle"
        case .savingMeeting: return "saving"
        case .polishingTranscript: return "polishing"
        case .diarizing: return "diarizing"
        case .chunking: return "chunking"
        case .embedding: return "embedding"
        case .summarizing: return "summarizing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private func handlePipelineStageChange() {
        guard let stage = pipeline?.stage else { return }
        // Don't paint anything over a *new* live recording — the post-run
        // toast belongs to the previous session.
        guard !recording.isRecording else {
            pipelineToastTask?.cancel()
            pipelineToast = nil
            return
        }
        switch stage {
        case .idle:
            pipelineToastTask?.cancel()
            pipelineToast = nil
        case .done, .failed:
            pipelineToast = stage
            pipelineToastTask?.cancel()
            pipelineToastTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { pipelineToast = nil }
            }
        default:
            // Working stages stay until they advance or hit done/failed.
            pipelineToast = stage
            pipelineToastTask?.cancel()
            pipelineToastTask = nil
        }
    }

    private func configurePipeline() {
        guard pipeline == nil else { return }
        let container = context.container
        let repository = MeetingsRepository(modelContainer: container)
        let llm = FoundationModelsSummaryGenerator()
        // Embedding service is the one component that can fail at init even
        // on a healthy device — `NLContextualEmbedding` requires a system
        // language asset that's normally pre-warmed by iOS but can be
        // missing on a fresh airplane-mode device. Earlier we returned
        // here on failure, which left `pipeline` and `qa` as nil — recording
        // would still work but the post-recording pipeline never wired up.
        // Now we fall back to a `NoOpEmbeddingService` so the pipeline
        // constructs and the meeting + summary path stays functional;
        // semantic Q&A is gated separately via `QAContext.semanticQAAvailable`
        // and the chat surfaces show a banner instead of silently failing.
        let embeddings: any EmbeddingService
        let semanticQAAvailable: Bool
        do {
            embeddings = try NLContextualEmbeddingService()
            semanticQAAvailable = true
        } catch {
            recording.lastError = "embedding fallback: \(error) — semantic Q&A disabled"
            embeddings = NoOpEmbeddingService()
            semanticQAAvailable = false
        }
        let store = SwiftDataVectorStore(modelContainer: container)
        // Bundle dir holding the FluidAudio Parakeet Core ML weights. Missing
        // dir = unbundled dev build; we pass nil and the pipeline silently
        // skips the polishing stage so behavior matches pre-Parakeet builds.
        // warm() is intentionally NOT called here — FluidAudioParakeetTranscriber
        // lazy-loads on first transcribe to avoid burning the ~3-4s Core ML
        // compile cost on app start.
        let batchASR: (any BatchASRService)? = {
            // Folder name (no -coreml suffix) matches FluidAudio's
            // Repo.parakeetV2.folderName, which it re-derives at load time.
            let modelDir = ModelLocator.parakeetModelDirectory()
            guard FileManager.default.fileExists(atPath: modelDir.path) else {
                return nil
            }
            return FluidAudioParakeetTranscriber(modelDirectory: modelDir)
        }()
        // Pyannote 3.1 + WeSpeaker v2 for offline post-recording diarization.
        // If the bundle isn't present (CI / fresh checkout) we wire `nil` so
        // the pipeline silently skips the .diarizing stage — same fall-through
        // pattern as Parakeet. We trigger warm() in the background to amortize
        // the ~1-2s Core ML compile cost off the recording-stop path.
        let diarization: (any DiarizationService)? = {
            guard
                let segURL = ModelLocator.segmentationModelURL(),
                let embURL = ModelLocator.embeddingModelURL()
            else { return nil }
            return PyannoteDiarizationService(segmentationURL: segURL, embeddingURL: embURL)
        }()
        if let diarization {
            Task.detached(priority: .utility) { try? await diarization.warm() }
        }
        let p = MeetingProcessingPipeline(
            repository: repository,
            embeddings: embeddings,
            llm: llm,
            batchASR: batchASR,
            diarization: diarization
        )
        pipeline = p
        recording.onSessionEnded = { transcript, duration, audioFileURL in
            Task { @MainActor in
                _ = await p.process(
                    transcript: transcript,
                    durationSeconds: duration,
                    audioFileURL: audioFileURL
                )
            }
        }

        let bm25 = BM25Index(modelContainer: container)
        let retriever = HierarchicalRetriever(embeddings: embeddings, store: store, bm25: bm25)
        // Prefer FluidAudio Kokoro 82M (Day 4). If the bundled weights aren't
        // present yet (fresh checkout, before Scripts/fetch-kokoro-models.sh
        // has run), fall back to AVSpeechSynthesizer so the build still runs
        // end-to-end. Same graceful-degradation pattern as the Parakeet path.
        //
        // We do NOT warm Kokoro at app launch anymore — its CoreML graphs
        // sit at ~300 MB resident, and adding that to the Foundation Models
        // LLM (~3 GB) + Pyannote/Parakeet during summary tipped iPhone Air
        // foreground over the jetsam ceiling. ChatThreadView.task fires
        // warm() lazily when the user opens a chat tab, so by the time
        // they're done holding the mic it's hot.
        let tts: any TTSService
        if ModelLocator.kokoroBundleDirectory() != nil {
            tts = KokoroTTSService()
        } else {
            tts = AVSpeechSynthesizerTTS()
        }
        let orchestrator = QAOrchestrator(retriever: retriever, tts: tts)
        let questionASR = QuestionASR()
        qa = QAContext(
            orchestrator: orchestrator,
            questionASR: questionASR,
            repository: repository,
            semanticQAAvailable: semanticQAAvailable
        )
        // Wire the interruption observer's TTS cancel hook now that the
        // orchestrator exists. We bind the closure here (not in
        // AftertalkApp.onAppear) because the orchestrator is constructed
        // lazily once the model container + embeddings are ready. Capturing
        // a strong reference is fine — the orchestrator outlives the closure
        // for the remainder of the app's lifetime.
        recording.onInterruptionCancelTTS = { [orchestrator] in
            await orchestrator.cancel()
        }
    }
}

/// Auto-dismissing post-recording status pill. Lives at the RootView
/// overlay level so it floats above whatever tab is showing once the
/// fullScreenCover has been dismissed by the recording ending. Working
/// stages persist until the next transition; `.done` / `.failed` clear
/// themselves after 3s via `pipelineToastTask` in RootView.
private struct PipelineToastView: View {
    @Environment(\.atPalette) private var palette
    let stage: ProcessingStage

    var body: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
            } else {
                Circle()
                    .fill(isFailed ? palette.accent : palette.positive)
                    .frame(width: 7, height: 7)
            }
            Text(label)
                .font(.atMono(10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(palette.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(palette.surface)
                .overlay(Capsule().stroke(palette.line, lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
        )
    }

    private var isWorking: Bool {
        switch stage {
        case .idle, .done, .failed: false
        default: true
        }
    }

    private var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }

    private var label: String {
        switch stage {
        case .idle: ""
        case .savingMeeting: "SAVING MEETING"
        case .polishingTranscript: "POLISHING TRANSCRIPT"
        case .diarizing: "IDENTIFYING SPEAKERS"
        case .chunking: "CHUNKING"
        case .embedding(let p, let t): "EMBEDDING \(p)/\(t)"
        case .summarizing: "GENERATING SUMMARY"
        case .done(_, let ms): "SUMMARY READY · \(Int(ms))MS"
        case .failed(let why): "FAILED · \(why.uppercased())"
        }
    }
}

#Preview {
    RootView(
        recording: RecordingViewModel(),
        perf: SessionPerfSampler(),
        interruptions: AudioInterruptionObserver()
    )
    .environment(PrivacyMonitor())
    .modelContainer(AftertalkPersistence.makeContainer())
}
