import SwiftUI

/// Quiet Studio design tokens. Direct port of the JSX palette + type + spacing
/// system from the AfterTalks design handoff (`design_handoff_aftertalks/`).
/// SF Pro Display / SF Pro / SF Mono / New York stand in for Inter Display /
/// Inter / JetBrains Mono / Fraunces — the handoff README explicitly calls
/// these out as perfect substitutes for the iOS native target.
///
/// Use these tokens, not raw hex literals, anywhere in `Aftertalk/UI/`.
/// Anything that takes a `palette` from JSX gets replaced with `AT.palette`
/// (light/dark resolved via `@Environment(\.colorScheme)`).
enum AT {
    // MARK: Palette

    struct Palette: Equatable {
        let bg: Color
        let surface: Color
        let surfaceAlt: Color
        let ink: Color
        let mute: Color
        let faint: Color
        let line: Color
        let lineStrong: Color
        let accent: Color
        let accentSoft: Color
        let positive: Color
        let sand: Color
        let moss: Color
    }

    static let light = Palette(
        bg: Color(hex: 0xECE4D2),
        surface: Color(hex: 0xF4EDDC),
        surfaceAlt: Color(hex: 0xE5DBC4),
        ink: Color(hex: 0x1F1A14),
        mute: Color(hex: 0x5A4F3F),
        faint: Color(hex: 0x857862),
        line: Color(hex: 0x1F1A14, opacity: 0.10),
        lineStrong: Color(hex: 0x1F1A14, opacity: 0.18),
        accent: Color(hex: 0x9C4A2B),
        accentSoft: Color(hex: 0xD88160),
        positive: Color(hex: 0x3F8852),
        sand: Color(hex: 0xC8A87C),
        moss: Color(hex: 0x7A8B6F)
    )

    static let dark = Palette(
        bg: Color(hex: 0x1A1612),
        surface: Color(hex: 0x231D17),
        surfaceAlt: Color(hex: 0x231D17),
        ink: Color(hex: 0xF0E7D3),
        mute: Color(hex: 0x9A8F7A),
        faint: Color(hex: 0x9A8F7A),
        line: Color(hex: 0xF0E7D3, opacity: 0.12),
        lineStrong: Color(hex: 0xF0E7D3, opacity: 0.12),
        accent: Color(hex: 0x9C4A2B),
        accentSoft: Color(hex: 0xD88160),
        positive: Color(hex: 0x3F8852),
        sand: Color(hex: 0xC8A87C),
        moss: Color(hex: 0x7A8B6F)
    )

    // MARK: Spacing & radius (8-point base, see handoff README §spacing)

    enum Space {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 28
        static let safeTop: CGFloat = 54
    }

    enum Radius {
        static let base: CGFloat = 12
        static let card: CGFloat = 16
        static let button: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: Motion

    enum Motion {
        /// Default spring-like ease used for tab change / view enter.
        static let standard: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
        /// Quick scale + fade for transcript fragments arriving live.
        static let fragment: Animation = .easeOut(duration: 0.36)
        /// Touch responsiveness on the hold-to-ask button.
        static let hold: Animation = .easeOut(duration: 0.18)
    }
}

// MARK: - Palette resolution

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: AT.Palette = AT.light
}

extension EnvironmentValues {
    /// Inject the resolved palette into the view tree so descendants don't
    /// each need a `@Environment(\.colorScheme)`.
    var atPalette: AT.Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Wrap the root view of a screen with this so children read `\.atPalette`.
    func atTheme() -> some View {
        modifier(ATThemeModifier())
    }
}

private struct ATThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let palette = scheme == .dark ? AT.dark : AT.light
        content
            .environment(\.atPalette, palette)
            .background(palette.bg.ignoresSafeArea())
            .tint(palette.accent)
    }
}

// MARK: - Typography

extension Font {
    /// Display titles (28-84pt). Inter Display → SF Pro Display rounded weight.
    static func atDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Body / paragraph copy (14-16pt). Inter → SF Pro.
    static func atBody(_ size: CGFloat = 14.5, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Mono metadata for timestamps, durations, audit numbers (10-11pt).
    /// JetBrains Mono → SF Mono.
    static func atMono(_ size: CGFloat = 10.5, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Italic display moments (quoted moments, asked questions). Fraunces → New York.
    static func atSerif(_ size: CGFloat = 19, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Hex Color helper

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
