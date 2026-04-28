import SwiftUI

/// "The moment a meeting becomes a memory." Shown after the user taps stop,
/// while `MeetingProcessingPipeline` walks through diarize → polish →
/// chunk/embed → summarize. The four-row checklist mirrors the JSX prototype
/// but maps onto the real `ProcessingStage` enum, so we never fake progress —
/// the breathing orb keeps cycling until `.done`, then settles into a check.
struct ProcessingView: View {
    let stage: ProcessingStage
    @Environment(\.atPalette) private var palette

    var body: some View {
        ZStack(alignment: .top) {
            background
            VStack(spacing: 0) {
                topRow
                    .padding(.horizontal, 28)
                    .padding(.top, AT.Space.safeTop)
                Spacer(minLength: 12)
                BreathingOrb(done: isDone)
                    .frame(width: 230, height: 230)
                Spacer(minLength: 12)
                titleBlock
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                stepsList
                    .padding(.horizontal, 28)
                    .padding(.bottom, 36)
            }
        }
        .atTheme()
    }

    private var background: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            RadialGradient(
                colors: [palette.surface.opacity(0.9), palette.bg],
                center: UnitPoint(x: 0.5, y: 0.32),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
        }
    }

    private var topRow: some View {
        HStack(alignment: .center) {
            QSEyebrow(isDone ? "Memory ready" : "Capture complete", color: palette.faint)
            Spacer()
            QSPrivacyBadge(compact: true)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 8) {
            QSTitle(
                text: isDone ? "Ready." : "Distilling the meeting.",
                size: 28,
                tracking: -0.8,
                color: palette.ink
            )
            QSBody(
                text: isDone
                    ? "Decisions, action items, and a fresh memory, all on this device."
                    : "Four small models, working in sequence. Nothing leaves the phone.",
                size: 13.5,
                color: palette.mute
            )
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var stepsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, s in
                stepRow(idx: idx, item: s)
            }
        }
    }

    private func stepRow(idx: Int, item: StepItem) -> some View {
        let state = stateFor(idx: idx)
        let active = idx <= currentIndex
        return HStack(alignment: .center, spacing: 12) {
            StepIcon(state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.atBody(13.5, weight: .medium))
                    .foregroundStyle(active ? palette.ink : palette.faint)
                Text(item.sub)
                    .font(.atMono(10, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(palette.faint)
            }
            Spacer()
            switch state {
            case .done:
                Text("DONE")
                    .font(.atMono(10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(palette.positive)
            case .active:
                ATListeningDots(color: palette.accent)
            case .pending:
                EmptyView()
            }
        }
        .padding(.vertical, 10)
        .opacity(idx > currentIndex ? 0.4 : 1)
        .animation(.easeOut(duration: 0.32), value: currentIndex)
        .overlay(alignment: .top) {
            if idx > 0 { QSDivider() }
        }
    }

    // MARK: - Stage mapping

    private struct StepItem {
        let label: String
        let sub: String
    }

    private let steps: [StepItem] = [
        .init(label: "Diarizing speakers", sub: "Pyannote · on-device"),
        .init(label: "Aligning transcript", sub: "Parakeet · streaming"),
        .init(label: "Distilling decisions", sub: "Foundation Models"),
        .init(label: "Indexing for memory", sub: "gte-small · embeddings"),
    ]

    /// Map the runtime `ProcessingStage` onto the visual 4-step checklist.
    /// We don't expose every internal stage — savingMeeting collapses into
    /// "Aligning transcript", embedding/chunking collapses into "Indexing".
    private var currentIndex: Int {
        switch stage {
        case .idle, .savingMeeting: 0
        case .diarizing: 0
        case .polishingTranscript: 1
        case .summarizing: 2
        case .chunking, .embedding: 3
        case .done: 4
        case .failed: currentIndexBeforeFailure
        }
    }

    /// On failure the checklist freezes wherever it last was. We cannot
    /// recover the exact frozen position from the enum so we fall back to
    /// "indexing" — the latest stage. UI shows the failure copy elsewhere.
    private var currentIndexBeforeFailure: Int { 3 }

    private var isDone: Bool {
        if case .done = stage { return true }
        return false
    }

    private func stateFor(idx: Int) -> StepState {
        if idx < currentIndex { return .done }
        if idx == currentIndex && !isDone { return .active }
        if idx == currentIndex && isDone { return .done }
        return .pending
    }
}

private enum StepState { case pending, active, done }

private struct StepIcon: View {
    let state: StepState
    @Environment(\.atPalette) private var palette

    var body: some View {
        switch state {
        case .done:
            ZStack {
                Circle()
                    .fill(palette.positive.opacity(0.18))
                    .frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.positive)
            }
        case .active:
            SpinnerRing(color: palette.accent)
                .frame(width: 22, height: 22)
        case .pending:
            Circle()
                .strokeBorder(palette.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: 22, height: 22)
        }
    }
}

private struct SpinnerRing: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// BreathingOrb lives in QSComponents.swift so the QA "thinking" phase can
// reuse the exact same visual without duplicating the 30Hz timeline + halo
// math. Same primitive, two screens.
