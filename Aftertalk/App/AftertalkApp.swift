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
    @AppStorage("aftertalk.onboarded") private var onboarded: Bool = false
    private let container: ModelContainer

    init() {
        self.container = AftertalkPersistence.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView(recording: recording)
                .environment(privacyMonitor)
                .modelContainer(container)
                .onAppear {
                    privacyMonitor.start()
                    // Privacy monitor wiring lives here (not in RootView's
                    // .task) so it survives tab switches and only fires once.
                    recording.privacyMonitor = privacyMonitor
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
