import SwiftData
import SwiftUI

@main
struct AftertalkApp: App {
    @State private var privacyMonitor = PrivacyMonitor()
    @AppStorage("aftertalk.onboarded") private var onboarded: Bool = false
    private let container: ModelContainer

    init() {
        self.container = AftertalkPersistence.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(privacyMonitor)
                .modelContainer(container)
                .onAppear {
                    privacyMonitor.start()
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
