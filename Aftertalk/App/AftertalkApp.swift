import SwiftData
import SwiftUI

@main
struct AftertalkApp: App {
    // Owned at app scope so a TabView re-render in RootView can never
    // deallocate it. Previously this lived as @State inside RootView and
    // tab switches could reset the VM, killing its long-lived AsyncStream
    // consumers (deltaTask, diagTask) while the audio engine kept running.
    @State private var recording = RecordingViewModel()
    @State private var privacyMonitor = PrivacyMonitor()
    /// Single in-app perf sampler. Runs the entire foreground app lifetime so
    /// recording + Q&A both land in the same CSV, charted as one timeline for
    /// the Day 6 perf chart. Settings exposes a share sheet to pull the file
    /// off device. Stops on background to avoid burning battery while the user
    /// is in another app.
    @State private var perf = SessionPerfSampler()
    @AppStorage("aftertalk.onboarded") private var onboarded: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        self.container = AftertalkPersistence.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView(recording: recording, perf: perf)
                .environment(privacyMonitor)
                .modelContainer(container)
                .onAppear {
                    privacyMonitor.start()
                    // Privacy monitor wiring lives here (not in RootView's
                    // .task) so it survives tab switches and only fires once.
                    recording.privacyMonitor = privacyMonitor
                    Task { await perf.start(eventLabel: "app_appear") }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await perf.start(eventLabel: "active") }
                    case .background, .inactive:
                        Task { await perf.record(event: "scene_\(phase == .background ? "background" : "inactive")") }
                    @unknown default:
                        break
                    }
                }
                .fullScreenCover(isPresented: .init(
                    get: { !onboarded },
                    set: { isPresented in
                        if !isPresented { onboarded = true }
                    }
                )) {
                    OnboardingFlow {
                        onboarded = true
                    }
                    .environment(privacyMonitor)
                }
        }
    }
}
