import SwiftData
import SwiftUI

@main
struct AftertalkApp: App {
    @State private var privacyMonitor = PrivacyMonitor()
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
        }
    }
}
