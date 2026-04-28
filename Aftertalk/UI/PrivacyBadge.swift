import SwiftUI

/// Wrapper around `QSPrivacyBadge` that maps the runtime `PrivacyMonitor.State`
/// onto the Quiet Studio "Sealed" visual. Sealed (offline) is the canonical
/// state — anything else escalates to a violation pill in the same shape.
struct PrivacyBadge: View {
    let state: PrivacyMonitor.State
    var compact: Bool = false

    var body: some View {
        switch state {
        case .offline:
            QSPrivacyBadge(compact: compact)
        case .unknown:
            statusPill(label: "Checking…", color: AT.light.faint, dotColor: AT.light.faint)
        case .onlineButIdle:
            statusPill(label: "Network active", color: Color(hex: 0xB14A26), dotColor: Color(hex: 0xB14A26))
        case .violation:
            statusPill(label: "Privacy alert", color: .red, dotColor: .red)
        }
    }

    private func statusPill(label: String, color: Color, dotColor: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .tracking(0.2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
                .overlay(Capsule().stroke(color.opacity(0.32), lineWidth: 0.5))
        )
    }
}
