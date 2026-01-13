import SwiftUI
import AIGlowKitDevTools

@main
struct AIGlowHarnessApp: App {
    init() {
        AIGlowHarnessPolicy.assertNoExternalDataAccess()
        AIGlowHarnessSnapshotRunner.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            AIGlowHarnessRootView()
        }
    }
}
