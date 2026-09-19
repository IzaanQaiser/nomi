import SwiftUI

/// Coordinates the first-run experience and the persistent notebook library.
struct RootView: View {
    @AppStorage("nomi.hasCompletedFirstLaunch") private var hasCompletedFirstLaunch = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firstProject: Project?

    var body: some View {
        ZStack {
            if hasCompletedFirstLaunch || firstProject != nil {
                ProjectsView(initialProject: firstProject)
                    .opacity(hasCompletedFirstLaunch ? 1 : 0)
                    .scaleEffect(hasCompletedFirstLaunch ? 1 : 0.992)
                    .allowsHitTesting(hasCompletedFirstLaunch)
                    .zIndex(0)
            }

            if !hasCompletedFirstLaunch {
                OnboardingFlowView(onCompleted: completeOnboarding)
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .background(NomiTheme.paper.ignoresSafeArea())
    }

    private func completeOnboarding(with project: Project) {
        // Construct the navigation stack and notebook canvas behind onboarding
        // first. Revealing it on the next main-actor turn avoids building the
        // PDF/PencilKit hierarchy in the same frame as the transition.
        firstProject = project
        Task { @MainActor in
            await Task.yield()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.38)) {
                hasCompletedFirstLaunch = true
            }
        }
    }
}

#Preview {
    RootView()
}
