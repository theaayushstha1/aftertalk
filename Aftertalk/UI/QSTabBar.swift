import SwiftUI

/// Quiet Studio bottom tab bar. Replaces the system `TabView` so we can:
///   1. Float a record FAB elevated ~20pt above the bar's visual center.
///   2. Render hairline + ultra-thin material in editorial palette tokens.
///   3. Keep label typography tight (atMono 9 / +1.6 tracking) — `TabView`
///      will not let us touch label fonts on iOS.
///
/// The center "tab" is actually the record FAB and is NOT one of `QSTab`'s
/// cases; it is rendered in the same HStack slot for layout symmetry.

@MainActor
enum QSTab: Hashable, CaseIterable {
    case meetings, search, chat, settings
}

@MainActor
struct QSTabBar: View {
    @Binding var selection: QSTab
    let recording: RecordingViewModel
    var onRecordTap: () -> Void

    @Environment(\.atPalette) private var palette

    /// Visual height of the bar itself (excludes the FAB lift + safe-area).
    static let barHeight: CGFloat = 64

    var body: some View {
        ZStack(alignment: .top) {
            // 0.5px hairline anchored at the very top of the bar surface.
            VStack(spacing: 0) {
                QSDivider()
                HStack(spacing: 0) {
                    item(.meetings, label: "Meetings", symbol: "square.grid.2x2")
                    item(.search,   label: "Search",   symbol: "magnifyingglass")
                    centerSpacer
                    item(.chat,     label: "Chat",     symbol: "bubble.left.and.bubble.right")
                    item(.settings, label: "Settings", symbol: "gearshape")
                }
                .frame(height: Self.barHeight)
            }
            .background(.ultraThinMaterial)

            // Floating FAB sits ~20pt above bar center.
            recordFAB
                .offset(y: -20)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Tab item

    private func item(_ tab: QSTab, label: String, symbol: String) -> some View {
        let active = selection == tab
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                selection = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                Text(label.uppercased())
                    .font(.atMono(9, weight: .medium))
                    .tracking(1.0)
            }
            .foregroundStyle(active ? palette.ink : palette.faint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Empty slot reserving space for the floating FAB so it stays centered
    /// even though it's drawn in a separate ZStack layer.
    private var centerSpacer: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    // MARK: - Record FAB

    private var recordFAB: some View {
        QSRecordFAB(isRecording: recording.isRecording, action: onRecordTap)
    }
}

// MARK: - QSRecordFAB

/// 64x64 floating record control rendered above the tab bar. Idle: `palette.ink`
/// with white concentric ring (Quiet Studio record glyph). Recording:
/// `palette.accent` with pulsing 4pt ring + stop square. Stays a control —
/// not a tab — so screen content does NOT change when tapped.
@MainActor
struct QSRecordFAB: View {
    let isRecording: Bool
    let action: () -> Void

    @Environment(\.atPalette) private var palette
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Pulsing ring — only visible while recording.
                Circle()
                    .stroke(palette.accent.opacity(0.45), lineWidth: 4)
                    .frame(width: 64, height: 64)
                    .scaleEffect(pulse ? 1.18 : 1.0)
                    .opacity(isRecording ? (pulse ? 0.0 : 0.7) : 0.0)

                // Core disc.
                Circle()
                    .fill(isRecording ? palette.accent : palette.ink)
                    .frame(width: 64, height: 64)
                    .shadow(color: (isRecording ? palette.accent : Color.black).opacity(0.22),
                            radius: 12, x: 0, y: 8)

                // Glyph: idle = concentric ring, recording = stop square.
                if isRecording {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(palette.bg)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .stroke(palette.bg, lineWidth: 2)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .fill(palette.bg)
                                .frame(width: 14, height: 14)
                        )
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
        .onAppear { syncPulse() }
        .onChange(of: isRecording) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        // Reset to base, then start a forever-repeating outward pulse.
        pulse = false
        guard isRecording else { return }
        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

#Preview {
    struct Demo: View {
        @State var tab: QSTab = .meetings
        let rec = RecordingViewModel()
        var body: some View {
            ZStack(alignment: .bottom) {
                Color(hex: 0xECE4D2).ignoresSafeArea()
                QSTabBar(selection: $tab, recording: rec, onRecordTap: {})
            }
            .atTheme()
        }
    }
    return Demo()
}
