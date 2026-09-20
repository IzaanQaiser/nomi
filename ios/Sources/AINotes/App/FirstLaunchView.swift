import SwiftUI

/// Shared visual tokens for the first-run experience. Future onboarding steps
/// should use these rather than introducing one-off colors and spacing.
enum NomiTheme {
    static let blue = Color(red: 0.10, green: 0.43, blue: 0.95)
    static let blueMuted = Color(red: 0.66, green: 0.80, blue: 0.98)
    static let paper = Color(red: 0.975, green: 0.980, blue: 0.990)
    static let surface = Color.white
    static let ink = Color(red: 0.055, green: 0.085, blue: 0.145)
    static let secondaryInk = Color(red: 0.38, green: 0.43, blue: 0.53)
    static let hairline = Color(red: 0.87, green: 0.89, blue: 0.93)
}

/// The first step of Nomi's first-run flow. It creates the same persisted
/// `Project` used by the rest of the app, so the course name entered here is
/// immediately available to sources, notes, chat, and shadowing.
struct FirstLaunchView: View {
    enum Phase: Equatable {
        case editing
        case creating
        case ready
    }

    let onProjectCreated: (Project) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isCourseFieldFocused: Bool
    @State private var phase: Phase = .editing
    @State private var errorMessage: String?
    @State private var showExplanation = false
    @State private var hasAppeared = false

    var body: some View {
        GeometryReader { proxy in
            let usesKeyboardLayout = isCourseFieldFocused || proxy.size.height < 560

            VStack(spacing: 0) {
                Spacer(minLength: usesKeyboardLayout ? 8 : 48)

                VStack(spacing: usesKeyboardLayout ? 14 : 34) {
                    hero(compact: usesKeyboardLayout)
                    CourseEntryView(
                        compact: usesKeyboardLayout,
                        phase: phase,
                        errorMessage: $errorMessage,
                        isFocused: $isCourseFieldFocused,
                        onContinue: continueTapped,
                        onShowExplanation: { showExplanation = true }
                    )
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 36)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)

                Spacer(minLength: usesKeyboardLayout ? 8 : 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.24),
                value: usesKeyboardLayout
            )
        }
        .background {
            NomiTheme.paper
                .ignoresSafeArea()
                .onTapGesture { isCourseFieldFocused = false }
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showExplanation) {
            HowNomiWorksView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) {
                    hasAppeared = true
                }
            }
        }
    }

    private func hero(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 22) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [NomiTheme.blue.opacity(0.13), NomiTheme.blue.opacity(0)],
                            center: .center,
                            startRadius: compact ? 28 : 52,
                            endRadius: compact ? 78 : 138
                        )
                    )
                    .frame(width: compact ? 156 : 276, height: compact ? 156 : 276)

                NomiView(pose: NomiPose(assetName: mascotAsset))
                    .frame(width: compact ? 94 : 150, height: compact ? 94 : 150)
                    .id(mascotAsset)
                    .transition(.opacity)
            }
            .frame(width: compact ? 166 : 286, height: compact ? 104 : 200)
            .animation(.easeInOut(duration: 0.22), value: mascotAsset)
            .accessibilityHidden(true)

            Text("I learn how you learn.\nI help when you need it.")
                .font(.system(size: compact ? 28 : 40, weight: .bold))
                .tracking(compact ? -0.4 : -0.8)
                .multilineTextAlignment(.center)
                .foregroundStyle(NomiTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var mascotAsset: String {
        switch phase {
        case .editing: "NomiIdle"
        case .creating: "NomiThinking"
        case .ready: "NomiConfirm"
        }
    }

    private func continueTapped(name: String) {
        isCourseFieldFocused = false
        errorMessage = nil
        phase = .creating

        Task { @MainActor in
            async let minimumThinkingTime: Void = Task.sleep(for: .seconds(1.75))

            let result: Result<Project, Error>
            do {
                result = .success(try await APIClient.shared.createProject(name: name))
            } catch {
                result = .failure(error)
            }

            _ = try? await minimumThinkingTime

            switch result {
            case let .success(project):
                phase = .ready
                try? await Task.sleep(for: .milliseconds(750))
                onProjectCreated(project)
            case let .failure(error):
                phase = .editing
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Owns the rapidly changing text state so typing does not invalidate the
/// mascot, glow, and full-screen onboarding layout on every keystroke.
private struct CourseEntryView: View {
    let compact: Bool
    let phase: FirstLaunchView.Phase
    @Binding var errorMessage: String?
    @FocusState.Binding var isFocused: Bool
    let onContinue: (String) -> Void
    let onShowExplanation: () -> Void

    @State private var courseName = ""

    private var normalizedCourseName: String {
        courseName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        !normalizedCourseName.isEmpty && phase == .editing
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 13) {
            Text("What are you working on?")
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(NomiTheme.ink)

            HStack(spacing: 12) {
                TextField("e.g. ECE 307, Calculus II…", text: $courseName)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(NomiTheme.ink)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                    .submitLabel(.continue)
                    .focused($isFocused)
                    .disabled(phase != .editing)
                    .onSubmit(continueTapped)
                    .onChange(of: courseName) { _, value in
                        if value.count > 80 {
                            courseName = String(value.prefix(80))
                        }
                        if errorMessage != nil { errorMessage = nil }
                    }

                Button(action: continueTapped) {
                    Group {
                        if phase == .creating {
                            ProgressView()
                                .tint(.white)
                        } else if phase == .ready {
                            Image(systemName: "checkmark")
                                .font(.system(size: 17, weight: .bold))
                        } else {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 18, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(buttonColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canContinue)
                .animation(.easeInOut(duration: 0.18), value: canContinue)
                .animation(.easeInOut(duration: 0.18), value: phase)
                .accessibilityLabel("Continue with this course")
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: compact ? 54 : 62)
            .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(fieldBorderColor, lineWidth: isFocused ? 1.5 : 1)
            }
            .shadow(color: NomiTheme.ink.opacity(0.07), radius: 14, y: 6)
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeInOut(duration: 0.18), value: canContinue)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityLabel("Could not create course. \(errorMessage)")
            } else if phase != .editing {
                Text(statusText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(phase == .ready ? Color.green : NomiTheme.secondaryInk)
                    .transition(.opacity)
            } else if !compact {
                Button(action: onShowExplanation) {
                    Label("How Nomi works", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(NomiTheme.secondaryInk)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .animation(.easeInOut(duration: 0.2), value: phase)
    }

    private var buttonColor: Color {
        switch phase {
        case .ready: Color.green
        case .creating: NomiTheme.blue
        case .editing: canContinue ? NomiTheme.blue : NomiTheme.blueMuted
        }
    }

    private var fieldBorderColor: Color {
        if errorMessage != nil { return .orange.opacity(0.8) }
        if isFocused || canContinue { return NomiTheme.blue.opacity(0.72) }
        return NomiTheme.hairline
    }

    private var statusText: String {
        switch phase {
        case .editing: ""
        case .creating: "Making space for \(normalizedCourseName)…"
        case .ready: "Ready."
        }
    }

    private func continueTapped() {
        guard canContinue else { return }
        onContinue(normalizedCourseName)
    }
}

private struct HowNomiWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                principle(
                    icon: "eye",
                    title: "Quiet by default",
                    detail: "Nomi stays beside your work instead of pulling you into a separate chat."
                )
                principle(
                    icon: "arrow.up.right",
                    title: "Helpful when it matters",
                    detail: "Small nudges appear when you are stuck. Deeper teaching waits until you ask for it."
                )
                principle(
                    icon: "lock.shield",
                    title: "Your course stays grounded",
                    detail: "Your notes and sources give each course its own context."
                )
                Spacer()
            }
            .padding(30)
            .background(NomiTheme.paper)
            .navigationTitle("How Nomi works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func principle(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(NomiTheme.blue)
                .frame(width: 38, height: 38)
                .background(NomiTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(NomiTheme.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("First launch") {
    FirstLaunchView { _ in }
}
