import SwiftUI

/// Owns onboarding navigation independently of the library navigation stack.
/// The draft project id is persisted so force-quitting between steps resumes
/// the same course instead of creating a duplicate backend project.
struct OnboardingFlowView: View {
    let onCompleted: (Project) -> Void

    @AppStorage("nomi.onboardingProjectID") private var draftProjectID = ""
    @State private var project: Project?
    @State private var isRestoring = false
    @State private var restorationError: String?
    @State private var hasAttemptedRestore = false

    var body: some View {
        ZStack {
            if let project {
                CourseContextView(project: project) {
                    draftProjectID = ""
                    onCompleted(project)
                }
            } else if isRestoring {
                ProgressView("Getting your course ready…")
                    .tint(NomiTheme.blue)
                    .foregroundStyle(NomiTheme.secondaryInk)
            } else if let restorationError {
                restoreFailure(message: restorationError)
            } else {
                FirstLaunchView { createdProject in
                    draftProjectID = createdProject.id
                    project = createdProject
                }
            }
        }
        .background(NomiTheme.paper.ignoresSafeArea())
        .task { await restoreDraftIfNeeded() }
    }

    private func restoreFailure(message: String) -> some View {
        VStack(spacing: 18) {
            Image("NomiNudge")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)

            Text("I couldn't reopen that course.")
                .font(.title2.bold())
                .foregroundStyle(NomiTheme.ink)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(NomiTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HStack(spacing: 12) {
                Button("Start over") {
                    draftProjectID = ""
                    restorationError = nil
                }
                .buttonStyle(.bordered)

                Button("Try again") {
                    hasAttemptedRestore = false
                    restorationError = nil
                    Task { await restoreDraftIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .tint(NomiTheme.blue)
            }
        }
        .padding(40)
    }

    @MainActor
    private func restoreDraftIfNeeded() async {
        guard !draftProjectID.isEmpty, !hasAttemptedRestore, project == nil else { return }
        hasAttemptedRestore = true
        isRestoring = true
        defer { isRestoring = false }

        do {
            project = try await APIClient.shared.getProject(id: draftProjectID)
        } catch {
            restorationError = error.localizedDescription
        }
    }
}
