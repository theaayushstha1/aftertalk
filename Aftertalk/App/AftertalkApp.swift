import SwiftUI

@main
struct AftertalkApp: App {
    @State private var privacyMonitor = PrivacyMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(privacyMonitor)
                .onAppear {
                    privacyMonitor.start()
                }
        }
    }
}
