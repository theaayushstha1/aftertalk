import SwiftUI

/// Engineering HUD. Only ever rendered in DEBUG builds — release builds get
/// an `EmptyView` shell so the submission video can never accidentally show
/// internal counters. The toggle in `RootView` (double-tap on the recording
/// surface) is preserved verbatim; in release the overlay just refuses to
/// paint anything regardless of the toggle state.
struct DebugOverlay: View {
    let recording: RecordingViewModel
    let privacy: PrivacyMonitor

    var body: some View {
        #if DEBUG
        debugBody
        #else
        EmptyView()
        #endif
    }

    #if DEBUG
    @Environment(\.atPalette) private var palette

    private var debugBody: some View {
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
                            .font(.atMono(10, weight: .medium))
                            .foregroundStyle(palette.accent)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .font(.atMono(10.5, weight: .medium))
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AT.Radius.base, style: .continuous))
                .padding(.top, 60)
                .padding(.trailing, 16)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(palette.faint)
            Text(v).foregroundStyle(palette.ink)
        }
    }
    #endif
}
