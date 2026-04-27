import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulse && isRecording ? 1.18 : 1.0)
                    .opacity(pulse && isRecording ? 0.0 : 0.7)

                Circle()
                    .fill(Color.red)
                    .frame(width: 96, height: 96)

                Image(isRecording ? "Stop" : "Mic")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}
