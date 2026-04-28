import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(PrivacyMonitor.self) private var privacy

    @State private var recording = RecordingViewModel()
    @State private var pipeline: MeetingProcessingPipeline?
    @State private var qa: QAContext?
    @State private var debugVisible = true

    var body: some View {
        TabView {
            recordTab
                .tabItem { Label("Record", systemImage: "mic.circle.fill") }

            MeetingsListView(qaContext: qa)
                .tabItem { Label("Meetings", systemImage: "list.bullet.rectangle.portrait") }
        }
        .task {
            configurePipeline()
            // Hand the privacy monitor to the VM so it can flip the
            // `isCapturingMeeting` flag during start/stop. Without this the
            // .violation state is unreachable and the auditable-privacy claim
            // is dead code.
            recording.privacyMonitor = privacy
        }
        .alert("Microphone access required", isPresented: .constant(recording.permissionDenied)) {
            Button("OK") { recording.permissionDenied = false }
        } message: {
            Text("Aftertalk needs your microphone to record meetings. Audio never leaves your device.")
        }
    }

    private var recordTab: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                header
                Spacer()
                transcriptPane
                if let stage = pipeline?.stage, stage != .idle {
                    PipelineStatusView(stage: stage)
                }
                Spacer()
                RecordButton(isRecording: recording.isRecording) {
                    Task { await recording.toggle() }
                }
                Spacer().frame(height: 16)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)

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
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aftertalk").font(.system(.title2, design: .rounded).weight(.bold))
                Text("Fully on-device meeting intelligence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PrivacyBadge(state: privacy.state)
        }
    }

    private var transcriptPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if recording.transcript.isEmpty {
                    Text(recording.isRecording ? "Listening…" : "Tap the button to start a meeting.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(recording.transcript)
                        .font(.system(.body, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
    RootView()
        .environment(PrivacyMonitor())
        .modelContainer(AftertalkPersistence.makeContainer())
}
