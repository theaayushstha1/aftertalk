import AVFoundation
import SwiftUI

/// Quiet Studio 3-screen onboarding. Mirrors `qs-onboarding.jsx`:
/// 1. The promise (privacy manifesto)
/// 2. Airplane mode (verify all interfaces are down)
/// 3. Microphone (request `AVAudioApplication.requestRecordPermission`)
///
/// Persistence is `@AppStorage("aftertalk.onboarded")`. The flow only
/// surfaces on cold start when that flag is false; `RootView` mounts it via
/// `.fullScreenCover` so the recording surface stays untouched. The
/// "Verify airplane mode" CTA reads `PrivacyMonitor.state` directly — we
/// surface a hairline-bordered banner if any interface is up so the user
/// has to physically toggle airplane mode before continuing. This is the
/// runtime half of the privacy invariant claimed in the README.
struct OnboardingFlow: View {
    /// Caller sets this to dismiss the cover and unlock the app.
    let onComplete: () -> Void

    @Environment(PrivacyMonitor.self) private var privacy
    @Environment(\.atPalette) private var palette

    @State private var step: Int = 0
    @State private var verifying: Bool = false
    @State private var bannerMessage: String?

    private let slides: [OnboardSlide] = [
        OnboardSlide(
            eyebrow: "The promise",
            title: "A meeting that\nnever leaves\nthe room.",
            body: "Aftertalk listens, transcribes, summarizes, and answers questions — all on this device. Your conversations are not training data. They are not a server problem. They are not anyone else's.",
            footnote: "You can verify it. Open the audit any time.",
            cta: "I want this",
            scene: .privacy
        ),
        OnboardSlide(
            eyebrow: "Step 1 of 2",
            title: "Airplane mode\nis the contract.",
            body: "Before recording, Aftertalk asks the system to confirm every interface is down. The badge in the corner turns green only when the room is sealed.",
            footnote: "Wi-Fi, cellular, Bluetooth, AirDrop. All of them.",
            cta: "Verify airplane mode",
            scene: .airplane
        ),
        OnboardSlide(
            eyebrow: "Step 2 of 2",
            title: "May we listen?",
            body: "Aftertalk needs the microphone to capture your meetings. Audio is processed by an on-device speech model. The raw waveform stays on this phone.",
            footnote: "You can revoke at any time in Settings.",
            cta: "Enable microphone",
            scene: .mic
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chapterDots
                .padding(.top, AT.Space.safeTop)
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
            illustration
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 28)
            copyBlock
                .padding(.horizontal, 28)
            if let bannerMessage {
                bannerView(bannerMessage)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            QSPrimaryButton(currentSlide.cta, action: handlePrimary)
                .padding(.horizontal, 28)
            backButton
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.bg.ignoresSafeArea())
        .atTheme()
    }

    private var currentSlide: OnboardSlide { slides[step] }

    // MARK: - Chapter dots

    private var chapterDots: some View {
        HStack(spacing: 8) {
            ForEach(slides.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(String(format: "%02d", i + 1))
                        .font(.atMono(10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(i <= step ? palette.accent : palette.faint)
                    Rectangle()
                        .fill(i <= step ? palette.accent : palette.line)
                        .frame(height: 1.5)
                        .frame(maxWidth: i == step ? 28 : .infinity)
                }
                .layoutPriority(i == step ? 0 : 1)
            }
        }
    }

    // MARK: - Hero illustration

    @ViewBuilder
    private var illustration: some View {
        switch currentSlide.scene {
        case .privacy: PrivacyScene()
        case .airplane: AirplaneScene(allClear: airplaneVerified)
        case .mic: MicScene()
        }
    }

    private var airplaneVerified: Bool {
        if case .offline = privacy.state { return true }
        return false
    }

    // MARK: - Copy block

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            QSEyebrow(currentSlide.eyebrow, color: palette.accent)
                .padding(.bottom, 12)
            QSTitle(
                text: currentSlide.title,
                size: 36,
                tracking: -1.2,
                color: palette.ink
            )
            .padding(.bottom, 16)
            QSBody(text: currentSlide.body, size: 15, color: palette.mute)
                .padding(.bottom, 8)
            Text(currentSlide.footnote)
                .font(.atSerif(13, weight: .regular))
                .italic()
                .foregroundStyle(palette.faint)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Banner

    private func bannerView(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text(msg)
                .font(.atBody(13, weight: .medium))
                .foregroundStyle(palette.ink)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AT.Radius.base, style: .continuous)
                .fill(palette.surfaceAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: AT.Radius.base, style: .continuous)
                        .stroke(palette.line, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Back button

    @ViewBuilder
    private var backButton: some View {
        if step > 0 {
            Button {
                withAnimation(AT.Motion.standard) {
                    bannerMessage = nil
                    step -= 1
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.atBody(12, weight: .medium))
                }
                .foregroundStyle(palette.faint)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        } else {
            Color.clear.frame(height: 22)
                .padding(.top, 10)
        }
    }

    // MARK: - Primary CTA logic

    private func handlePrimary() {
        switch currentSlide.scene {
        case .privacy:
            advance()
        case .airplane:
            verifyAirplane()
        case .mic:
            requestMic()
        }
    }

    private func advance() {
        bannerMessage = nil
        if step < slides.count - 1 {
            withAnimation(AT.Motion.standard) { step += 1 }
        } else {
            onComplete()
        }
    }

    private func verifyAirplane() {
        // PrivacyMonitor's `state` is published by `pathUpdateHandler`; the
        // first read may be `.unknown` if the user hits the CTA in the same
        // run-loop tick the view appeared. Force a re-read by checking
        // current state and if .unknown, gently nudge them to wait.
        switch privacy.state {
        case .offline:
            advance()
        case .unknown:
            withAnimation { bannerMessage = "Checking interfaces… try again in a second." }
        case .onlineButIdle(let ifaces), .violation(let ifaces):
            let list = ifaces.joined(separator: ", ")
            withAnimation {
                bannerMessage = "Still seeing \(list). Toggle airplane mode and tap verify again."
            }
        }
    }

    private func requestMic() {
        Task {
            let granted: Bool
            switch AVAudioApplication.shared.recordPermission {
            case .granted: granted = true
            case .denied: granted = false
            case .undetermined:
                granted = await AVAudioApplication.requestRecordPermission()
            @unknown default: granted = false
            }
            await MainActor.run {
                if granted {
                    advance()
                } else {
                    withAnimation {
                        bannerMessage = "Microphone is off. Open Settings → Aftertalk → Microphone to enable, then come back."
                    }
                }
            }
        }
    }
}

// MARK: - Slide model

private struct OnboardSlide {
    let eyebrow: String
    let title: String
    let body: String
    let footnote: String
    let cta: String
    let scene: Scene

    enum Scene { case privacy, airplane, mic }
}

// MARK: - Hero scenes

/// Slide 1 — concentric ink rings around an accent disc. Reads as
/// "everything orbits this device."
private struct PrivacyScene: View {
    @Environment(\.atPalette) private var palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let breathe = (sin(t * 1.4) + 1) / 2
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .stroke(palette.line, lineWidth: 0.5)
                        .frame(width: CGFloat(120 + i * 38), height: CGFloat(120 + i * 38))
                        .opacity(0.6 - Double(i) * 0.1)
                }
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [palette.accent, palette.accent.opacity(0.85)],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0,
                            endRadius: 140
                        )
                    )
                    .frame(width: 110, height: 110)
                    .scaleEffect(1 + breathe * 0.04)
                    .shadow(color: palette.accent.opacity(0.4), radius: 28, x: 0, y: 16)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(0.95)
            }
            .frame(width: 280, height: 280)
        }
    }
}

/// Slide 2 — paper-card with airplane glyph. When `allClear` is true the
/// card glows positive and a check overlays. Driven by PrivacyMonitor.
private struct AirplaneScene: View {
    let allClear: Bool
    @Environment(\.atPalette) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(allClear ? palette.positive.opacity(0.5) : palette.line, lineWidth: 0.5)
                )
                .frame(width: 220, height: 220)
                .shadow(color: Color.black.opacity(0.08), radius: 24, x: 0, y: 14)
            VStack(spacing: 18) {
                Image(systemName: "airplane")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(allClear ? palette.positive : palette.ink)
                Text(allClear ? "ROOM SEALED" : "AIRPLANE MODE")
                    .font(.atMono(11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(allClear ? palette.positive : palette.faint)
            }
            if allClear {
                ZStack {
                    Circle()
                        .fill(palette.positive)
                        .frame(width: 36, height: 36)
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(palette.bg)
                }
                .offset(x: 92, y: -92)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

/// Slide 3 — single mic glyph centered in a wide accent halo. Same
/// breathing-orb pattern but lighter weight to read as "ready to listen."
private struct MicScene: View {
    @Environment(\.atPalette) private var palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let breathe = (sin(t * 1.6) + 1) / 2
            ZStack {
                Circle()
                    .stroke(palette.accent, lineWidth: 0.5)
                    .frame(width: 240, height: 240)
                    .opacity(0.25 + breathe * 0.25)
                    .scaleEffect(1 + breathe * 0.03)
                Circle()
                    .stroke(palette.accent, lineWidth: 0.5)
                    .frame(width: 180, height: 180)
                    .opacity(0.4 + breathe * 0.3)
                Circle()
                    .fill(palette.ink)
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 14)
                Image(systemName: "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(palette.bg)
            }
            .frame(width: 260, height: 260)
        }
    }
}
