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
        .task { configurePipeline() }
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
        let p = MeetingProcessingPipeline(repository: repository, embeddings: embeddings, llm: llm)
        pipeline = p
        recording.onSessionEnded = { transcript, duration in
            Task { @MainActor in
                _ = await p.process(transcript: transcript, durationSeconds: duration)
            }
        }

        let retriever = HierarchicalRetriever(embeddings: embeddings, store: store)
        let tts = AVSpeechSynthesizerTTS()
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
