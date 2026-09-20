import SwiftUI

@MainActor
@Observable
final class ClassroomSession {
    enum Phase: Equatable {
        case picking
        case preparing
        case teaching
    }

    let project: Project
    let seed: ClassroomSeed

    var phase: Phase = .picking
    var topic = ""
    var suggestions: [String] = []
    var isLoadingSuggestions = false
    var lesson: ClassroomLesson?
    let player = ClassroomLessonPlayer()
    var errorMessage: String?
    private var prepareGeneration = 0

    init(project: Project, seed: ClassroomSeed = ClassroomSeed()) {
        self.project = project
        self.seed = seed
        if let topic = seed.topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            self.topic = topic
        }
    }

    var isPreparing: Bool { phase == .preparing }

    var displayTitle: String {
        guard let lesson else { return topic }
        let heading = lesson.title.isEmpty ? lesson.topic : lesson.title
        if heading.localizedCaseInsensitiveContains(project.name) {
            return heading
        }
        return "\(project.name) \(heading)"
    }

    func loadSuggestions() async {
        guard suggestions.isEmpty else { return }
        isLoadingSuggestions = true
        defer { isLoadingSuggestions = false }
        do {
            suggestions = try await APIClient.shared.classroomSuggestions(projectId: project.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startIfSeeded() async {
        let topic = self.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, phase == .picking, lesson == nil else { return }
        await startLesson(topic)
    }

    func startLesson(_ question: String) async {
        let topic = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, phase != .preparing else { return }
        self.topic = topic
        lesson = nil
        player.reset()
        errorMessage = nil
        phase = .preparing
        prepareGeneration += 1
        let generation = prepareGeneration

        do {
            let prepared = try await APIClient.shared.prepareClassroom(
                projectId: project.id,
                topic: topic,
                promptContext: seed.promptContext
            )
            guard generation == prepareGeneration else { return }
            if prepared.inScope, !prepared.beats.isEmpty {
                lesson = prepared
                player.load(prepared)
                phase = .teaching
            } else {
                phase = .picking
                errorMessage = prepared.reason
                    ?? "That isn’t covered in this project’s sources. Pick a topic from the course."
            }
        } catch {
            guard generation == prepareGeneration else { return }
            phase = .picking
            errorMessage = error.localizedDescription
        }
    }

    func cancelPrepare() {
        prepareGeneration += 1
        phase = .picking
        lesson = nil
        player.reset()
    }

    func resetToPicker() {
        prepareGeneration += 1
        phase = .picking
        topic = ""
        lesson = nil
        player.reset()
        errorMessage = nil
    }
}

/// Course-grounded lesson picker, then a classroom stage with a board and Nomi.
/// `ClassroomSeed` is the later hook from live tutoring.
struct ClassroomView: View {
    let project: Project
    let seed: ClassroomSeed

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: ClassroomSession
    @State private var hasAppeared = false
    @State private var showLessonSources = false

    init(project: Project, seed: ClassroomSeed = ClassroomSeed()) {
        self.project = project
        self.seed = seed
        _session = State(initialValue: ClassroomSession(project: project, seed: seed))
    }

    var body: some View {
        Group {
            switch session.phase {
            case .picking:
                picker
            case .preparing:
                preparing
            case .teaching:
                stage
            }
        }
        .background(NomiTheme.paper.ignoresSafeArea())
        .preferredColorScheme(.light)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await session.loadSuggestions()
            await session.startIfSeeded()
        }
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) { hasAppeared = true }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.player.stopPlayback()
            }
        }
        .onChange(of: showLessonSources) { _, isPresented in
            if isPresented {
                session.player.stopPlayback()
            }
        }
        .onDisappear {
            session.player.stopPlayback()
        }
        .sheet(isPresented: $showLessonSources) {
            NavigationStack {
                if let lesson = session.lesson {
                    ClassroomSourcesSheet(lesson: lesson)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var picker: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 700

            VStack(spacing: 0) {
                classroomHeader(title: "Classroom") {
                    dismiss()
                }

                Spacer(minLength: compact ? 8 : 28)

                VStack(spacing: compact ? 18 : 28) {
                    pickerHero(compact: compact)
                    ClassroomPickerForm(
                        compact: compact,
                        projectName: project.name,
                        suggestions: session.suggestions,
                        isLoadingSuggestions: session.isLoadingSuggestions,
                        isSending: false,
                        errorMessage: session.errorMessage,
                        onStart: { topic in
                            Task { await session.startLesson(topic) }
                        }
                    )
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 36)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)

                Spacer(minLength: compact ? 8 : 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var preparing: some View {
        ZStack(alignment: .topLeading) {
            ExamLoadingView(
                phrases: [
                    "Opening your sources…",
                    "Checking this is in the course…",
                    "Laying out the lesson…",
                    "Getting the board ready…",
                ]
            )

            classroomHeader(title: session.topic.isEmpty ? "Classroom" : session.topic) {
                session.cancelPrepare()
            }
            .padding(.top, 0)
        }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    session.resetToPicker()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.bold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NomiTheme.ink)
                .background(NomiTheme.surface, in: Circle())
                .overlay(Circle().stroke(NomiTheme.hairline, lineWidth: 1))
                .accessibilityLabel("Back to topics")

                Text(session.displayTitle)
                    .font(.title3.bold())
                    .foregroundStyle(NomiTheme.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let lesson = session.lesson {
                    Button {
                        showLessonSources = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("using \(lesson.sources.count) \(lesson.sources.count == 1 ? "source" : "sources")")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NomiTheme.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show sources for this lesson")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)

            HStack(alignment: .center, spacing: 22) {
                ClassroomBoardView(player: session.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 14) {
                    NomiView(pose: session.player.playbackState == .playing ? .talk : .idle)
                        .frame(width: 168, height: 168)
                        .accessibilityLabel("Nomi")

                    if let beat = session.player.currentBeat {
                        Text(beat.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NomiTheme.secondaryInk)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: 190)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            ClassroomTransportBar(player: session.player)
                .padding(.top, 18)
                .padding(.bottom, 22)
        }
    }

    private func classroomHeader(title: String, back: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.bold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NomiTheme.ink)
            .background(NomiTheme.surface, in: Circle())
            .overlay(Circle().stroke(NomiTheme.hairline, lineWidth: 1))
            .accessibilityLabel("Back")

            Text(title)
                .font(.title3.bold())
                .foregroundStyle(NomiTheme.ink)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func pickerHero(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [NomiTheme.blue.opacity(0.13), NomiTheme.blue.opacity(0)],
                            center: .center,
                            startRadius: compact ? 28 : 48,
                            endRadius: compact ? 78 : 120
                        )
                    )
                    .frame(width: compact ? 156 : 240, height: compact ? 156 : 240)

                NomiView(pose: .idle)
                    .frame(width: compact ? 96 : 138, height: compact ? 96 : 138)
            }
            .frame(height: compact ? 104 : 168)
            .accessibilityHidden(true)

            Text("What would you like to learn?")
                .font(.system(size: compact ? 26 : 34, weight: .bold))
                .tracking(-0.5)
                .multilineTextAlignment(.center)
                .foregroundStyle(NomiTheme.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Owns the rapidly changing text so typing does not redraw Nomi.
private struct ClassroomPickerForm: View {
    let compact: Bool
    let projectName: String
    let suggestions: [String]
    let isLoadingSuggestions: Bool
    let isSending: Bool
    let errorMessage: String?
    let onStart: (String) -> Void

    @FocusState private var isFocused: Bool
    @State private var input = ""

    private var normalized: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool {
        !normalized.isEmpty && !isSending
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                TextField("Ask about anything in \(projectName)…", text: $input, axis: .vertical)
                    .font(.system(size: 17))
                    .foregroundStyle(NomiTheme.ink)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.go)
                    .focused($isFocused)
                    .lineLimit(1...3)
                    .disabled(isSending)
                    .onSubmit(start)
                    .onChange(of: input) { _, value in
                        if value.count > 2000 { input = String(value.prefix(2000)) }
                    }

                Button(action: start) {
                    Group {
                        if isSending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        canStart ? NomiTheme.blue : NomiTheme.blueMuted,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .animation(.easeInOut(duration: 0.18), value: canStart)
                .accessibilityLabel("Start lesson")
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(minHeight: compact ? 54 : 62)
            .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(fieldBorder, lineWidth: isFocused || canStart ? 1.5 : 1)
            }
            .shadow(color: NomiTheme.ink.opacity(0.07), radius: 14, y: 6)
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeInOut(duration: 0.18), value: canStart)

            if isLoadingSuggestions {
                ProgressView("Finding useful topics…")
                    .tint(NomiTheme.blue)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            } else if suggestions.isEmpty {
                Text("Add course files and I’ll suggest topics from this class.")
                    .font(.subheadline)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .multilineTextAlignment(.center)
            } else {
                Text("suggestions from your course")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NomiTheme.secondaryInk)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(suggestions, id: \.self, content: chip)
                    }
                    VStack(spacing: 10) {
                        ForEach(suggestions, id: \.self, content: chip)
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var fieldBorder: Color {
        if errorMessage != nil { return .orange.opacity(0.8) }
        if isFocused || canStart { return NomiTheme.blue.opacity(0.72) }
        return NomiTheme.hairline
    }

    private func chip(_ topic: String) -> some View {
        let selected = normalized.caseInsensitiveCompare(topic) == .orderedSame
        return Button {
            input = topic
        } label: {
            Text(topic)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .white : NomiTheme.ink)
                .padding(.horizontal, 16)
                .frame(height: 42)
                .background(selected ? NomiTheme.blue : NomiTheme.surface, in: Capsule())
                .overlay {
                    Capsule().stroke(selected ? Color.clear : NomiTheme.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.16), value: selected)
    }

    private func start() {
        guard canStart else { return }
        isFocused = false
        onStart(normalized)
    }
}

private struct ClassroomBoardView: View {
    let player: ClassroomLessonPlayer

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(NomiTheme.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(NomiTheme.hairline, lineWidth: 1)
                }
                .shadow(color: NomiTheme.ink.opacity(0.04), radius: 18, y: 8)

            if let beat = player.currentBeat {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Text(player.positionLabel.uppercased())
                            .font(.caption.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(NomiTheme.blue)

                        ProgressView(value: player.progress)
                            .tint(NomiTheme.blue)
                    }

                    Text(beat.title)
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(NomiTheme.ink)

                    Group {
                        slidePreview(for: beat.slide)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    Text(beat.speaking)
                        .font(.subheadline)
                        .foregroundStyle(NomiTheme.secondaryInk)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            NomiTheme.paper,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .padding(28)
            } else {
                ProgressView()
                    .tint(NomiTheme.blue)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lesson board")
        .accessibilityValue(boardValue)
    }

    private var boardValue: String {
        guard let beat = player.currentBeat else { return "Waiting for Nomi" }
        return "\(player.positionLabel), \(beat.title). \(beat.speaking)"
    }

    @ViewBuilder
    private func slidePreview(for slide: ClassroomSlide) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !slide.subtitle.isEmpty {
                Text(slide.subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.blue)
            }
            if !slide.equation.isEmpty {
                Text(slide.equation)
                    .font(.title3.weight(.semibold).monospaced())
                    .foregroundStyle(NomiTheme.ink)
            }
            if !slide.body.isEmpty {
                Text(slide.body)
                    .font(.body)
                    .foregroundStyle(NomiTheme.ink)
            }
            ForEach(slide.bullets, id: \.self) { bullet in
                Text("• \(bullet)")
                    .font(.body)
                    .foregroundStyle(NomiTheme.ink)
            }
            ForEach(Array(slide.steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
                    .font(.body)
                    .foregroundStyle(NomiTheme.ink)
            }
            if !slide.question.isEmpty {
                Text(slide.question)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(NomiTheme.ink)
            }
            if !slide.mermaid.isEmpty {
                Text("Diagram")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NomiTheme.secondaryInk)
            }
            if !slide.callout.isEmpty {
                Text(slide.callout)
                    .font(.footnote)
                    .foregroundStyle(NomiTheme.secondaryInk)
            }
        }
    }
}

private struct ClassroomTransportBar: View {
    let player: ClassroomLessonPlayer

    var body: some View {
        HStack(spacing: 24) {
            control(
                "previous",
                systemImage: "backward.end.fill",
                enabled: player.canMoveBackward,
                action: player.moveBackward
            )

            control(
                playbackTitle,
                systemImage: playbackIcon,
                prominent: true,
                action: player.togglePlayback
            )

            control(
                "next",
                systemImage: "forward.end.fill",
                enabled: player.canMoveForward,
                action: player.moveForward
            )

            control("ask nomi", systemImage: "bubble.left.fill", enabled: false) {}
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(NomiTheme.surface, in: Capsule())
        .overlay(Capsule().stroke(NomiTheme.hairline, lineWidth: 1))
        .shadow(color: NomiTheme.ink.opacity(0.06), radius: 12, y: 5)
    }

    private var playbackTitle: String {
        switch player.playbackState {
        case .playing: "pause"
        case .completed: "replay"
        case .ready, .paused: "play"
        }
    }

    private var playbackIcon: String {
        switch player.playbackState {
        case .playing: "pause.fill"
        case .completed: "arrow.counterclockwise"
        case .ready, .paused: "play.fill"
        }
    }

    private func control(
        _ title: String,
        systemImage: String,
        enabled: Bool = true,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(height: 20)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(prominent ? Color.white : NomiTheme.ink)
            .frame(minWidth: 68, minHeight: 48)
            .background(prominent ? NomiTheme.blue : Color.clear, in: Capsule())
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

private struct ClassroomSourcesSheet: View {
    let lesson: ClassroomLesson
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(lesson.summary.isEmpty ? "Nomi is teaching from these files." : lesson.summary)
                    .font(.subheadline)
                    .foregroundStyle(NomiTheme.secondaryInk)
            }

            Section("Sources") {
                ForEach(lesson.sources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: iconName(for: source.kind))
                            .foregroundStyle(source.kind == "pdf" ? Color.red.opacity(0.82) : NomiTheme.blue)
                            .frame(width: 28)
                        Text(source.sourceTitle)
                            .foregroundStyle(NomiTheme.ink)
                            .lineLimit(2)
                    }
                }
            }

            if !lesson.citations.isEmpty {
                Section("Passages") {
                    ForEach(lesson.citations) { citation in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(citation.sourceTitle)
                                .font(.subheadline.weight(.semibold))
                            Text(citation.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Lesson sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "png": "photo.fill"
        case "pdf", "docx": "doc.fill"
        default: "text.alignleft"
        }
    }
}

#Preview {
    ClassroomView(project: Project(id: "preview", name: "ECE 358", createdAt: .now))
}
