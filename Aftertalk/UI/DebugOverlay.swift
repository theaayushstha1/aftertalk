import SwiftUI

struct DebugOverlay: View {
    let recording: RecordingViewModel
    let privacy: PrivacyMonitor

    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    row("TTFT", recording.ttftMillis.map { String(format: "%.0f ms", $0) } ?? "—")
                    row("State", recording.isRecording ? "REC" : "idle")
                    row("Mic", recording.micPermission)
                    row("Samples", "\(recording.samplesIn)")
                    row("Events", "\(recording.eventsIn)")
                    row("ASR", recording.asrActive ? "active" : "idle")
                    row("Add/Err", "\(recording.asrAddCalls)/\(recording.asrAddErrors)")
                    row("Start/Stop", "\(recording.asrStarts)/\(recording.asrStops)")
                    row("Privacy", String(describing: privacy.state).split(separator: "(").first.map(String.init) ?? "—")
                    if let err = recording.lastError {
                        Text(err)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .font(.caption.monospaced())
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 60)
                .padding(.trailing, 16)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Text(v).foregroundStyle(.primary)
        }
    }
}
