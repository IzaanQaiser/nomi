import SwiftUI

/// Coordinates the first-run experience and the persistent notebook library.
struct RootView: View {
    @AppStorage("nomi.hasCompletedFirstLaunch") private var hasCompletedFirstLaunch = false
    @State private var firstProject: Project?

    var body: some View {
        Group {
            if hasCompletedFirstLaunch {
                ProjectsView(initialProject: firstProject)
            } else {
                OnboardingFlowView { project in
                    firstProject = project
                    hasCompletedFirstLaunch = true
                }
            }
        }
    }
}

#Preview {
    RootView()
}
