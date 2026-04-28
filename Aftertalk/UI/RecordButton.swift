import SwiftUI

/// Quiet Studio recording control. Two visual states:
///
/// 1. Idle — 76pt mic FAB, ink fill on warm-sand bg, two outer halo rings
///    that fade in as the user touches down. Reads as "press to begin
///    listening."
///
/// 2. Recording — same 76pt frame, accent fill, stop-square glyph, slow
///    breathing halo. Reads as "tap once to finish & summarize."
///
/// We keep the hit-target identical between states so the muscle-memory
/// from the JSX prototype carries over.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    @Environment(\.atPalette) private var palette
    @State private var pressed = false
    @State private var breathe = false

    var body: some View {
        Button(action: action) {
            ZStack {
                outerHalo
                middleHalo
                core
                glyph
            }
            .frame(width: 130, height: 130)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressed: $pressed))
        .accessibilityLabel(isRecording ? "Stop and summarize" : "Start recording")
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            } else {
                breathe = false
            }
        }
    }

    private var outerHalo: some View {
        Circle()
            .fill((isRecording ? palette.accent : palette.ink).opacity(0.06))
            .frame(width: 130, height: 130)
            .scaleEffect(breathe ? 1.05 : 1.0)
            .opacity(pressed ? 1 : (isRecording ? 1 : 0.0))
    }

    private var middleHalo: some View {
        Circle()
            .fill((isRecording ? palette.accent : palette.ink).opacity(0.10))
            .frame(width: 102, height: 102)
            .scaleEffect(breathe ? 1.04 : 1.0)
            .opacity(pressed || isRecording ? 1 : 0.0)
    }

    private var core: some View {
        Circle()
            .fill(isRecording ? palette.accent : palette.ink)
            .frame(width: 76, height: 76)
            .shadow(color: (isRecording ? palette.accent : Color.black).opacity(0.18),
                    radius: 14, x: 0, y: 12)
            .scaleEffect(pressed ? 0.94 : 1.0)
            .animation(AT.Motion.hold, value: pressed)
    }

    private var glyph: some View {
        Group {
            if isRecording {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(palette.bg)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(palette.bg)
            }
        }
        .scaleEffect(pressed ? 0.94 : 1.0)
        .animation(AT.Motion.hold, value: pressed)
    }
}

/// Surfaces a `pressed` flag to the parent — used to drive halo + scale.
private struct PressStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                pressed = newValue
            }
    }
}

// MARK: - ImmersiveWaveform

/// 64 procedural sine-wave bars stacked horizontally. Animation is driven by
/// a timeline that accumulates a phase value at ~60Hz, then each bar's height
/// is the sum of three offset sines clamped against an envelope. Matches the
/// JSX `ImmersiveWaveform` exactly (N=64, multipliers 0.42 / 0.13 / 0.7,
/// envelope sin(x*pi)*0.6+0.4).
struct ImmersiveWaveform: View {
    var height: CGFloat = 180
    var isActive: Bool = true

    @Environment(\.atPalette) private var palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 3.6 // ~tick * 0.06 at 60Hz
            GeometryReader { proxy in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<bars, id: \.self) { i in
                        bar(index: i, phase: phase, total: proxy.size.width)
                    }
                }
                .frame(height: proxy.size.height)
            }
        }
        .frame(height: height)
    }

    private let bars = 64

    private func bar(index i: Int, phase: Double, total: CGFloat) -> some View {
        let x = Double(i) / Double(bars)
        let env = sin(x * .pi) * 0.6 + 0.4
        let a =
            sin(phase + Double(i) * 0.42) * 0.5 +
            sin(phase * 1.7 + Double(i) * 0.13) * 0.3 +
            sin(phase * 0.6 + Double(i) * 0.7) * 0.2
        let raw = abs(a) * env
        let v = max(0.04, isActive ? raw : 0.1)
        let h = max(3.0, v * Double(height) * 0.8)
        let opacity = 0.6 + v * 0.4
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [palette.accent, palette.accent.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: h)
            .opacity(opacity)
            .animation(.easeOut(duration: 0.09), value: h)
    }
}
