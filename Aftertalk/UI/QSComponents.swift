import SwiftUI

// MARK: - QSEyebrow
/// Uppercase metadata label sitting above a title or block. 10.5pt, 700 weight,
/// +1.6 letter spacing. Light/dark agnostic — caller picks the color (`faint`
/// or `accent` are the typical choices).
struct QSEyebrow: View {
    let text: String
    var color: Color
    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold, design: .default))
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

// MARK: - QSTitle
/// Editorial display title with strong negative tracking. Match by passing
/// `size` + `tracking`; leave defaults for the standard 32pt/-1 ramp.
struct QSTitle: View {
    let text: String
    var size: CGFloat = 32
    var weight: Font.Weight = .semibold
    var tracking: CGFloat = -1
    var color: Color
    var body: some View {
        Text(text)
            .font(.atDisplay(size, weight: weight))
            .tracking(tracking)
            .lineSpacing(0.04 * size)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - QSBody
/// Standard paragraph copy.
struct QSBody: View {
    let text: String
    var size: CGFloat = 14.5
    var color: Color
    var body: some View {
        Text(text)
            .font(.atBody(size))
            .lineSpacing(0.55 * size - size + 2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - QSStat
/// One column inside the meetings list header stat card. Big tabular number
/// with an uppercased eyebrow label below.
struct QSStat: View {
    let value: String
    let label: String
    var valueColor: Color
    @Environment(\.atPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.atDisplay(26, weight: .semibold))
                .tracking(-0.6)
                .monospacedDigit()
                .foregroundStyle(valueColor)
            QSEyebrow(label, color: palette.faint)
        }
    }
}

// MARK: - QSPrivacyBadge
/// "Sealed · on this device" pill. Persistent in app chrome, never modal,
/// never dismissable. Color and shape are fixed; the only variant is `compact`
/// which drops the trailing copy and shrinks padding.
struct QSPrivacyBadge: View {
    var compact: Bool = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        let bg = dark ? Color(red: 122/255, green: 139/255, blue: 111/255).opacity(0.18)
                      : Color(red: 122/255, green: 139/255, blue: 111/255).opacity(0.16)
        let border = dark ? Color(red: 122/255, green: 139/255, blue: 111/255).opacity(0.30)
                          : Color(red: 122/255, green: 139/255, blue: 111/255).opacity(0.32)
        let fg = dark ? Color(red: 164/255, green: 183/255, blue: 154/255)
                      : Color(red: 92/255, green: 112/255, blue: 88/255)
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: 0x3F8852))
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(Color(hex: 0x3F8852, opacity: 0.18), lineWidth: 3)
                )
            Text(compact ? "Sealed" : "Sealed · on this device")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .tracking(0.2)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(
            Capsule()
                .fill(bg)
                .overlay(Capsule().stroke(border, lineWidth: 0.5))
        )
    }
}

// MARK: - QSChip
/// Small pill used for tags, scope indicators, citations, etc.
struct QSChip: View {
    let label: String
    var icon: String? = nil
    var color: Color? = nil
    var dot: Bool = false
    var mono: Bool = false
    @Environment(\.atPalette) private var palette
    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            if dot {
                Circle()
                    .fill(color ?? palette.accent)
                    .frame(width: 5, height: 5)
            }
            Text(label)
                .font(mono
                      ? .atMono(10.5, weight: .medium)
                      : .system(size: 10.5, weight: .semibold))
                .tracking(0.2)
        }
        .foregroundStyle(color ?? palette.mute)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(palette.surface)
                .overlay(Capsule().stroke(palette.line, lineWidth: 0.5))
        )
    }
}

// MARK: - QSCite
/// Citation pill with a quote-bracket icon, used inside Q&A answers.
struct QSCite: View {
    let label: String
    @Environment(\.atPalette) private var palette
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "quote.opening")
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.atMono(10.5, weight: .medium))
                .tracking(0.1)
                .lineLimit(1)
        }
        .foregroundStyle(palette.mute)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(palette.surfaceAlt)
                .overlay(Capsule().stroke(palette.line, lineWidth: 0.5))
        )
    }
}

// MARK: - QSPrimaryButton
/// Ink-on-bg primary CTA used at the bottom of onboarding + settings flows.
/// 54pt height, label flush-left with an arrow flush-right.
struct QSPrimaryButton: View {
    let title: String
    let trailingIcon: String
    let action: () -> Void
    @Environment(\.atPalette) private var palette
    init(_ title: String, trailingIcon: String = "arrow.right", action: @escaping () -> Void) {
        self.title = title
        self.trailingIcon = trailingIcon
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.atDisplay(15, weight: .semibold))
                Spacer()
                Image(systemName: trailingIcon)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(palette.bg)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: AT.Radius.button, style: .continuous)
                    .fill(palette.ink)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - QSGhostButton
/// Outline-only secondary button used for "Verify raw audit log" etc.
struct QSGhostButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    @Environment(\.atPalette) private var palette
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                }
                Text(title)
                    .font(.atDisplay(13, weight: .medium))
            }
            .foregroundStyle(palette.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AT.Radius.base * 1.2, style: .continuous)
                    .stroke(palette.line, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - QSDivider
/// 0.5pt hairline divider — matches the JSX `borderTop: 0.5px solid line`.
/// SwiftUI's default `Divider` is too heavy for the editorial layout.
struct QSDivider: View {
    @Environment(\.atPalette) private var palette
    var body: some View {
        Rectangle()
            .fill(palette.line)
            .frame(height: 0.5)
    }
}

// MARK: - BreathingOrb
/// Quiet Studio thinking-state orb — 230pt accent disc with a 30Hz sin breath
/// driving scale + halo opacity. Used by ProcessingView (post-recording
/// pipeline) and ChatThreadView (Q&A retrieve→generate gap). When `done` is
/// true the orb settles into a 1.1x scale, halo locks at 0.5 opacity, and a
/// white check mark fades in.
struct BreathingOrb: View {
    let done: Bool
    @Environment(\.atPalette) private var palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = (sin(t * 1.6) + 1) / 2
            let scale = done ? 1.1 : 1 + breathe * 0.08
            let haloOpacity = done ? 0.5 : 0.3 + breathe * 0.4

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(palette.accent, lineWidth: 0.5)
                        .padding(CGFloat(-i) * 18)
                        .opacity(haloOpacity * (1 - Double(i) * 0.25))
                        .scaleEffect(1 + breathe * 0.04 * Double(i + 1))
                }
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    palette.accent,
                                    palette.accent.opacity(0.85),
                                ],
                                center: UnitPoint(x: 0.35, y: 0.30),
                                startRadius: 0,
                                endRadius: 220
                            )
                        )
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.4), Color.white.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 80, height: 50)
                        .blur(radius: 6)
                        .offset(y: -34)
                }
                .shadow(color: palette.accent.opacity(0.45), radius: 36, x: 0, y: 22)
                .scaleEffect(scale)
                .animation(done ? AT.Motion.standard : nil, value: scale)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

// MARK: - Listening dots
/// Three-dot loading affordance that matches the JSX `ListeningDots`. Used
/// during the recording-listening state and the processing pipeline.
struct ATListeningDots: View {
    var color: Color
    @State private var t: Double = 0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 3, height: 3)
                    .opacity(opacity(for: i))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                t = 1
            }
        }
    }
    private func opacity(for i: Int) -> Double {
        // Stagger by 150ms via phase. Base wave is sin-shaped between 0.3..1
        let phase = (t * 1.0) - Double(i) * 0.15
        let s = sin(phase * 2 * .pi)
        return 0.3 + (max(0, s) * 0.7)
    }
}
