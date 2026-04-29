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

    @State private var pipeline: MeetingProcessingPipeline?
    @State private var qa: QAContext?
    @State private var debugVisible = false
    @State private var selectedTab: QSTab = .meetings

    init(recording: RecordingViewModel, perf: SessionPerfSampler) {
        self.recording = recording
        self.perf = perf
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
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: selectedTab)
        .task { configurePipeline() }
        .alert("Microphone access required", isPresented: .constant(recording.permissionDenied)) {
            Button("OK") { recording.permissionDenied = false }
        } message: {
            Text("Aftertalk needs your microphone to record meetings. Audio never leaves your device.")
        }
        .fullScreenCover(isPresented: .constant(recording.isRecording)) {
            recordingSurface
        }
    }

    // MARK: - Tab routing

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .meetings:
            MeetingsListView(qaContext: qa)
        case .search:
            SearchView()
        case .chat:
            GlobalChatView(qaContext: qa)
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
                timer
                fragmentLabel
                ImmersiveWaveform(height: 180, isActive: recording.isRecording)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 6)
                transcriptPane
                if let stage = pipeline?.stage, stage != .idle {
                    PipelineStatusView(stage: stage)
                        .padding(.bottom, 8)
                }
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
        HStack(alignment: .center) {
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

    private var statusEyebrow: some View {
        HStack(spacing: 6) {
            if recording.isRecording {
                Circle()
                    .fill(palette.accent)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle().stroke(palette.accent.opacity(0.18), lineWidth: 4)
                    )
            }
            Text(recording.isRecording ? "RECORDING · LIVE" : "READY · TAP TO BEGIN")
                .font(.atMono(10, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(recording.isRecording ? palette.accent : palette.faint)
        }
        .padding(.bottom, 14)
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
                    Text(recording.transcript)
                        .font(.atBody(15))
                        .lineSpacing(4)
                        .foregroundStyle(palette.ink)
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
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: .infinity)
    }

    private func configurePipeline() {
        guard pipeline == nil else { return }
        let container = context.container
        let repository = MeetingsRepository(modelContainer: container)
        let llm = FoundationModelsSummaryGenerator()
        let embeddings: any EmbeddingService
        do {
            embeddings = try NLContextualEmbeddingService()
        } catch {
            recording.lastError = "embedding: \(error)"
            return
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

        let retriever = HierarchicalRetriever(embeddings: embeddings, store: store)
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
        qa = QAContext(orchestrator: orchestrator, questionASR: questionASR, repository: repository)
    }
}

private struct PipelineStatusView: View {
    let stage: ProcessingStage

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .opacity(isWorking ? 1 : 0)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var isWorking: Bool {
        switch stage {
        case .idle, .done, .failed: false
        default: true
        }
    }

    private var label: String {
        switch stage {
        case .idle: ""
        case .savingMeeting: "Saving meeting…"
        case .polishingTranscript: "Polishing transcript…"
        case .diarizing: "Identifying speakers…"
        case .chunking: "Chunking transcript…"
        case .embedding(let p, let t): "Embedding chunks (\(p)/\(t))"
        case .summarizing: "Generating summary…"
        case .done(_, let ms): "Summary ready (\(Int(ms)) ms)"
        case .failed(let why): "Failed: \(why)"
        }
    }
}

#Preview {
    RootView(recording: RecordingViewModel(), perf: SessionPerfSampler())
        .environment(PrivacyMonitor())
        .modelContainer(AftertalkPersistence.makeContainer())
}
