import SwiftUI

struct RootView: View {
    @State private var recording = RecordingViewModel()
    @Environment(PrivacyMonitor.self) private var privacy
    @State private var debugVisible = true

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                header
                Spacer()
                transcriptPane
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
        .alert("Microphone access required", isPresented: .constant(recording.permissionDenied)) {
            Button("OK") { recording.permissionDenied = false }
        } message: {
            Text("Aftertalk needs your microphone to record meetings. Audio never leaves your device.")
        }
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
}

#Preview {
    RootView()
        .environment(PrivacyMonitor())
}
