import SwiftUI

struct PrivacyBadge: View {
    let state: PrivacyMonitor.State

    var body: some View {
        HStack(spacing: 6) {
            Image(iconName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(color)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }

    private var label: String {
        switch state {
        case .unknown: "Checking…"
        case .offline: "Airplane mode"
        case .onlineButIdle: "Online (idle)"
        case .violation: "Privacy alert"
        }
    }

    private var iconName: String {
        switch state {
        case .unknown: "Radio"
        case .offline: "Plane"
        case .onlineButIdle: "Radio"
        case .violation: "WifiOff"
        }
    }

    private var color: Color {
        switch state {
        case .unknown: .gray
        case .offline: .green
        case .onlineButIdle: .orange
        case .violation: .red
        }
    }
}
