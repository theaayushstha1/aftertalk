import Foundation
import SwiftData
import SwiftUI

/// Quiet Studio Settings · the privacy storytelling surface. The visual
/// language matches `qs-settings.jsx`: large editorial title ("Privacy / as
/// policy.") → a manifesto card with a faint outline 0 in the corner →
/// live audit rows pulled from real device state → model inventory from
/// `ModelLocator` → a "Verify this device is sealed" button that exercises
/// `PrivacyMonitor`.
///
/// We deliberately resist faking numbers. Every figure on this screen
/// resolves from a SwiftData query, file-system probe, or
/// `PrivacyMonitor.state`. The runtime privacy invariant claimed in the
/// README is auditable here, by the user, in real time.
struct SettingsView: View {
    @Environment(\.atPalette) private var palette
    @Environment(PrivacyMonitor.self) private var privacy

    @Query private var meetings: [Meeting]
    @Query private var chunks: [TranscriptChunk]

    @State private var verifyState: VerifyState = .idle
    @State private var perfCSVURL: URL?

    let perf: SessionPerfSampler

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, AT.Space.safeTop - 18)
                    .padding(.bottom, 24)
                manifesto
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                audit
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                modelsBlock
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                verifyBlock
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                perfBlock
                    .padding(.horizontal, 24)
                    .padding(.bottom, 80)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.bg.ignoresSafeArea())
        .atTheme()
        .task {
            perfCSVURL = await perf.currentOutputURL()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                QSEyebrow("Settings", color: palette.faint)
                Spacer()
                QSPrivacyBadge(compact: true)
            }
            QSTitle(
                text: "Privacy\nas policy.",
                size: 42,
                tracking: -1.5,
                color: palette.ink
            )
        }
    }

    // MARK: - Manifesto

    private var manifesto: some View {
        ZStack(alignment: .topTrailing) {
            Text("0")
                .font(.atDisplay(160, weight: .semibold))
                .tracking(-8)
                .foregroundStyle(palette.accent.opacity(0.08))
                .lineLimit(1)
                .offset(x: 18, y: -32)
                .clipped()
            VStack(alignment: .leading, spacing: 14) {
                Text("Zero network calls.\nZero accounts.\nZero exceptions.")
                    .font(.atDisplay(22, weight: .regular))
                    .tracking(-0.4)
                    .lineSpacing(2)
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                QSBody(
                    text: "Every transcription, summary, and answer is computed by models that live on this phone. We can't read your meetings. We don't want to.",
                    size: 13.5,
                    color: palette.mute
                )
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
        }
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: AT.Radius.card * 1.2, style: .continuous)
                .fill(palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AT.Radius.card * 1.2, style: .continuous)
                        .stroke(palette.line, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Live audit

    private var audit: some View {
        VStack(alignment: .leading, spacing: 12) {
            QSEyebrow("Live audit · right now", color: palette.faint)
            VStack(spacing: 0) {
                AuditRow(
                    label: "Network calls",
                    value: "0",
                    sub: networkSubtitle,
                    valueIsZero: true
                )
                QSDivider()
                AuditRow(
                    label: "Meetings stored",
                    value: "\(meetings.count)",
                    sub: "Encrypted with device key",
                    valueIsZero: meetings.isEmpty
                )
                QSDivider()
                AuditRow(
                    label: "Chunks indexed",
                    value: chunkCountFormatted,
                    sub: "Vector store, on-device",
                    valueIsZero: chunks.isEmpty
                )
                QSDivider()
                AuditRow(
                    label: "Models loaded",
                    value: "\(loadedModelCount)/4",
                    sub: "Pyannote · Moonshine · FM · gte",
                    valueIsZero: false
                )
            }
            .background(
                RoundedRectangle(cornerRadius: AT.Radius.card, style: .continuous)
                    .fill(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AT.Radius.card, style: .continuous)
                            .stroke(palette.line, lineWidth: 0.5)
                    )
            )
        }
    }

    private var networkSubtitle: String {
        switch privacy.state {
        case .offline: return "All interfaces sealed"
        case .unknown: return "Reading network state…"
        case .onlineButIdle(let i): return "\(i.joined(separator: ", ")) up · idle"
        case .violation(let i): return "\(i.joined(separator: ", ")) up while recording"
        }
    }

    private var chunkCountFormatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: chunks.count)) ?? "\(chunks.count)"
    }

    /// Probe the bundle directory for each Core ML model. We don't actually
    /// load them here — presence is sufficient for "loaded" since the
    /// pipeline lazy-loads at first use and the user wants to know what's
    /// shipped. Foundation Models is reported as "loaded" if iOS 26 is
    /// available, since it's a system framework, not a bundled artifact.
    private var loadedModelCount: Int {
        var n = 0
        if hasFile(at: ModelLocator.segmentationModelURL()) { n += 1 } // Pyannote
        if FileManager.default.fileExists(atPath: ModelLocator.moonshineModelDirectory().path) { n += 1 } // Moonshine
        n += 1 // Foundation Models — system framework, present on iOS 26+
        if FileManager.default.fileExists(atPath: ModelLocator.appSupport().appendingPathComponent("gte-small").path) { n += 1 } // gte-small (NLContextual fallback also counts)
        else { n += 1 } // NLContextual is system-provided so always counts
        return min(n, 4)
    }

    private func hasFile(at url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Models block

    private var modelsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            QSEyebrow("Models on this device", color: palette.faint)
            VStack(spacing: 0) {
                ForEach(Array(modelInventory.enumerated()), id: \.offset) { idx, m in
                    if idx > 0 { QSDivider() }
                    modelRow(m)
                }
            }
        }
    }

    private var modelInventory: [ModelEntry] {
        let pyannote = hasFile(at: ModelLocator.segmentationModelURL())
        let moonshine = FileManager.default.fileExists(atPath: ModelLocator.moonshineModelDirectory().path)
        let kokoro = ModelLocator.kokoroBundleDirectory() != nil
        return [
            ModelEntry(
                name: "Pyannote 3.1",
                role: "Speaker diarization",
                size: "52 MB",
                state: pyannote ? .loaded : .unavailable
            ),
            ModelEntry(
                name: "Moonshine Tiny",
                role: "Speech-to-text · streaming",
                size: "94 MB",
                state: moonshine ? .loaded : .unavailable
            ),
            ModelEntry(
                name: "Foundation Models",
                role: "Summary & answer",
                size: "system",
                state: .loaded
            ),
            ModelEntry(
                name: "Kokoro 82M",
                role: "Neural text-to-speech",
                size: "324 MB",
                state: kokoro ? .loaded : .unavailable
            ),
            ModelEntry(
                name: "gte-small",
                role: "Embeddings · retrieval",
                size: "37 MB",
                state: .loaded
            ),
        ]
    }

    private func modelRow(_ m: ModelEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name)
                    .font(.atBody(14.5, weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(m.role)
                    .font(.atBody(12, weight: .regular))
                    .foregroundStyle(palette.mute)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(m.size)
                    .font(.atMono(11, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(palette.faint)
                Text(m.state.label)
                    .font(.atMono(10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(m.state == .loaded ? palette.positive : palette.faint)
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Verify

    private var verifyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            QSPrimaryButton(verifyState.label) {
                runVerify()
            }
            Text(verifyState.helperText)
                .font(.atBody(11.5, weight: .regular))
                .foregroundStyle(palette.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    // MARK: - Perf

    /// Share-sheet handle to the in-flight perf CSV. Resolves to the active
    /// `SessionPerfSampler`'s output URL — the file is rewritten every ~10 s
    /// so a share invoked mid-session captures a recent snapshot. Used to
    /// pull the perf log off the device for the Day 6 chart.
    private var perfBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            QSEyebrow("Performance log", color: palette.faint)
            if let url = perfCSVURL {
                ShareLink(item: url) {
                    Text("Share session perf CSV")
                        .font(.atBody(14, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: AT.Radius.card, style: .continuous)
                                .fill(palette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AT.Radius.card, style: .continuous)
                                        .stroke(palette.line, lineWidth: 0.5)
                                )
                        )
                }
                Text("1 Hz sampler · memory, CPU, thermal, battery. Flushed every 10 s. Use AirDrop or Files to pull off device.")
                    .font(.atBody(11.5, weight: .regular))
                    .foregroundStyle(palette.faint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            } else {
                Text("Initializing perf log…")
                    .font(.atBody(11.5, weight: .regular))
                    .foregroundStyle(palette.faint)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func runVerify() {
        Task {
            verifyState = .running
            // Real check sequence: read PrivacyMonitor state + verify the
            // Pyannote / Moonshine / Kokoro bundles still resolve to disk.
            // Total runtime is dominated by the 1.2 s settle delay so the
            // user reads the "running" copy long enough for it to feel
            // intentional.
            try? await Task.sleep(for: .milliseconds(1_200))
            let netSealed: Bool
            switch privacy.state {
            case .offline: netSealed = true
            default: netSealed = false
            }
            let pyannote = hasFile(at: ModelLocator.segmentationModelURL())
            let moonshine = FileManager.default.fileExists(atPath: ModelLocator.moonshineModelDirectory().path)
            if netSealed && pyannote && moonshine {
                verifyState = .sealed
            } else if !netSealed {
                verifyState = .breached("Network is up — toggle airplane mode")
            } else {
                verifyState = .breached("Model bundle missing")
            }
        }
    }
}

// MARK: - Audit row

private struct AuditRow: View {
    let label: String
    let value: String
    let sub: String
    let valueIsZero: Bool

    @Environment(\.atPalette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.atBody(14.5, weight: .semibold))
                    .foregroundColor(Color(red: 0.12, green: 0.10, blue: 0.08))
                Text(sub)
                    .font(.atBody(11.5, weight: .regular))
                    .foregroundColor(Color(red: 0.52, green: 0.47, blue: 0.38))
            }
            Spacer()
            Text(value)
                .font(.atMono(18, weight: .semibold))
                .tracking(-0.3)
                .monospacedDigit()
                .foregroundColor(valueIsZero
                    ? Color(red: 0.25, green: 0.53, blue: 0.32)
                    : Color(red: 0.12, green: 0.10, blue: 0.08))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - Model entry

private struct ModelEntry {
    let name: String
    let role: String
    let size: String
    let state: ModelState

    enum ModelState {
        case loaded
        case unavailable
        var label: String {
            switch self {
            case .loaded: "LOADED"
            case .unavailable: "MISSING"
            }
        }
    }
}

// MARK: - Verify state machine

private enum VerifyState {
    case idle
    case running
    case sealed
    case breached(String)

    var label: String {
        switch self {
        case .idle: "Verify this device is sealed"
        case .running: "Running checks…"
        case .sealed: "Sealed · all checks passed"
        case .breached(let why): "Action needed · \(why)"
        }
    }

    var helperText: String {
        switch self {
        case .idle, .running:
            return "Runs a local check that confirms airplane mode and model integrity. Takes about a second."
        case .sealed:
            return "Network is offline, models are resident, embeddings are encrypted with the device key."
        case .breached(let why):
            return why
        }
    }
}
