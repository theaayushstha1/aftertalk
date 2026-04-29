import SwiftUI
import UIKit

/// Non-blocking pill that surfaces during a recording when the device drops
/// below 10% battery. Suggestion only — the user owns the decision to stop.
/// We never auto-stop recording: a meeting half-captured is more useful than
/// a meeting cut short by a heuristic.
///
/// Battery monitoring is enabled at app launch by `SessionPerfSampler.start`,
/// so `UIDevice.current.batteryLevel` returns a real value here. We poll on
/// the `batteryLevelDidChangeNotification` (fires per integer percent change)
/// plus a 30s safety tick in case the system coalesces notifications during
/// throttled foreground work.
struct LowBatteryBanner: View {
    @Environment(\.atPalette) private var palette
    @State private var level: Float = UIDevice.current.batteryLevel

    private static let threshold: Float = 0.10

    var body: some View {
        Group {
            if shouldShow {
                HStack(spacing: 8) {
                    Image(systemName: "battery.25")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text("LOW BATTERY · \(percentString)")
                        .font(.atMono(10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(palette.ink)
                    Text("Recording continues — stop when you're ready.")
                        .font(.atBody(11))
                        .foregroundStyle(palette.mute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(palette.surface)
                        .overlay(Capsule().stroke(palette.line, lineWidth: 0.5))
                )
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            level = UIDevice.current.batteryLevel
        }
        .task {
            // First-paint refresh + slow safety poll. The notification covers
            // the common case; this catches the cold path where the app
            // resumed from background and missed the discrete-percent event.
            level = UIDevice.current.batteryLevel
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                level = UIDevice.current.batteryLevel
            }
        }
    }

    private var shouldShow: Bool {
        // batteryLevel is -1 when monitoring is off; treat as "unknown, hide".
        level >= 0 && level < Self.threshold
    }

    private var percentString: String {
        guard level >= 0 else { return "—" }
        return "\(Int((level * 100).rounded()))%"
    }
}
