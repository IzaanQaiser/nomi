import SwiftUI

@main
struct AINotesApp: App {
    init() {
#if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "nomi.debugReplayOnboardingOnLaunch") {
            defaults.set(false, forKey: "nomi.hasCompletedFirstLaunch")
            defaults.removeObject(forKey: "nomi.onboardingProjectID")
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
