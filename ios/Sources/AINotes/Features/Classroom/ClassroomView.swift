import SwiftUI

struct ClassroomQAExchange: Identifiable, Equatable {
    let id = UUID()
    let question: String
    let answer: String
}

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
    var isAsking = false
    var askInput = ""
    var isListening = false
    var isSendingAsk = false
    var askError: String?
    var exchanges: [ClassroomQAExchange] = []

    private var prepareGeneration = 0
    private var askGeneration = 0
    private var voice: VoiceListener?

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
        return "\(project.name) · \(heading)"
    }

    var visibleExchanges: [ClassroomQAExchange] {
        Array(exchanges.suffix(2))
    }

    var askHistory: [ClassroomHistoryMessage] {
        exchanges.suffix(3).flatMap {
            [
                ClassroomHistoryMessage(role: "user", content: $0.question),
                ClassroomHistoryMessage(role: "assistant", content: $0.answer),
            ]
        }
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
        resetAskState()
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
        resetAskState()
        phase = .picking
        lesson = nil
        player.reset()
    }

    func resetToPicker() {
        prepareGeneration += 1
        resetAskState()
        phase = .picking
        topic = ""
        lesson = nil
        player.reset()
        errorMessage = nil
    }

    func leaveClassroom() {
        askGeneration += 1
        cancelListening()
        isSendingAsk = false
        player.stopPlayback()
    }

    func beginAsk() {
        guard phase == .teaching, !isAsking else { return }
        isAsking = true
        askError = nil
        player.pauseForAsk()
        cancelListening()
    }

    func continueLesson() {
        cancelListening()
        askGeneration += 1
        isSendingAsk = false
        askError = nil
        isAsking = false
        player.resumeLessonAfterAsk()
    }

    func resetAskState() {
        askGeneration += 1
        cancelListening()
        isAsking = false
        isSendingAsk = false
        askError = nil
        askInput = ""
        exchanges = []
        player.stopAnswerSpeech()
    }

    func toggleListening() async {
        if isListening {
            cancelListening()
            return
        }
        guard isAsking, !isSendingAsk else { return }
        player.stopAnswerSpeech()
        let listener = voice ?? VoiceListener()
        voice = listener
        listener.onPartial = { [weak self] text in
            self?.askInput = String(text.prefix(2000))
        }
        listener.onFinished = { [weak self] text in
            guard let self else { return }
            self.isListening = false
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.askError = "I didn’t catch that. Type it, or try the mic again."
                return
            }
            self.askInput = String(trimmed.prefix(2000))
            Task { await self.sendAsk() }
        }
        listener.onError = { [weak self] message in
            self?.isListening = false
            self?.askError = message
        }
        let allowed = await listener.requestAccess()
        guard allowed else {
            askError = "Allow microphone and speech recognition to ask out loud."
            return
        }
        do {
            askError = nil
            isListening = true
            try listener.start()
        } catch {
            isListening = false
            askError = error.localizedDescription
        }
    }

    func sendAsk() async {
        let question = askInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAsking, !question.isEmpty, !isSendingAsk else { return }
        cancelListening()
        player.stopAnswerSpeech()
        askError = nil
        isSendingAsk = true
        askGeneration += 1
        let generation = askGeneration
        do {
            let response = try await APIClient.shared.teach(
                projectId: project.id,
                question: question,
                history: askHistory,
                promptContext: lessonPromptContext()
            )
            guard generation == askGeneration, isAsking else { return }
            isSendingAsk = false
            askInput = ""
            let answer = response.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            exchanges.append(ClassroomQAExchange(question: question, answer: answer))
            if exchanges.count > 3 {
                exchanges.removeFirst(exchanges.count - 3)
            }
            player.speakAnswer(answer) {}
        } catch {
            guard generation == askGeneration, isAsking else { return }
            isSendingAsk = false
            askError = error.localizedDescription
        }
    }

    func lessonPromptContext() -> String {
        var lines: [String] = []
        if let lesson {
            lines.append("Lesson topic: \(lesson.topic)")
            if !lesson.title.isEmpty {
                lines.append("Lesson title: \(lesson.title)")
            }
        }
        if let beat = player.currentBeat {
            let slide = beat.slide
            lines.append("Current beat: \(beat.title)")
            lines.append("Current slide layout: \(slide.layout.rawValue)")
            lines.append("Current slide title: \(slide.title)")
            if !slide.subtitle.isEmpty { lines.append("Slide subtitle: \(slide.subtitle)") }
            if !slide.body.isEmpty { lines.append("Slide body: \(slide.body)") }
            if !slide.equation.isEmpty { lines.append("Slide equation: \(slide.equation)") }
            if !slide.caption.isEmpty { lines.append("Slide caption: \(slide.caption)") }
            if !slide.callout.isEmpty { lines.append("Slide callout: \(slide.callout)") }
            if !slide.question.isEmpty { lines.append("Slide question: \(slide.question)") }
            if !slide.bullets.isEmpty {
                lines.append("Slide bullets: \(slide.bullets.joined(separator: "; "))")
            }
            if !slide.steps.isEmpty {
                lines.append("Slide steps: \(slide.steps.joined(separator: "; "))")
            }
            lines.append("Current narration: \(beat.speaking)")
        }
        if let handoff = seed.promptContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !handoff.isEmpty {
            lines.append("Original tutoring handoff: \(handoff)")
        }
        return String(lines.joined(separator: "\n").prefix(4000))
    }

    private func cancelListening() {
        isListening = false
        voice?.cancel()
    }
}

/// Course-grounded lesson picker, then a slide lesson with Nomi narrating.
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
        .onChange(of: session.phase) { _, phase in
            if phase == .teaching {
                session.resetAskState()
                session.player.play()
            } else {
                session.resetAskState()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.leaveClassroom()
            }
        }
        .onChange(of: showLessonSources) { _, isPresented in
            if isPresented {
                session.player.stopPlayback()
                session.player.stopAnswerSpeech()
            }
        }
        .onDisappear {
            session.leaveClassroom()
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
                        canRetry: !session.topic.isEmpty,
                        onStart: { topic in
                            Task { await session.startLesson(topic) }
                        },
                        onRetry: {
                            Task { await session.startLesson(session.topic) }
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
                    "Finding the right material…",
                    "Building your lesson…",
                    "Putting the visuals together…",
                ]
            )

            classroomHeader(title: session.topic.isEmpty ? "Classroom" : session.topic) {
                session.cancelPrepare()
            }
            .padding(.top, 0)
        }
    }

    private var stage: some View {
        GeometryReader { proxy in
            let sideWidth = min(320, max(240, proxy.size.width * 0.27))

            VStack(spacing: 0) {
                stageHeader

                HStack(alignment: .top, spacing: 22) {
                    if let slide = session.player.currentSlide {
                        ClassroomSlideView(
                            slide: slide,
                            progressLabel: session.player.positionLabel
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView()
                            .tint(NomiTheme.blue)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    VStack(spacing: 16) {
                        NomiView(pose: nomiPose)
                            .frame(width: min(168, sideWidth - 24), height: min(168, sideWidth - 24))
                            .accessibilityLabel("Nomi")

                        if session.isAsking {
                            ClassroomAskCard(session: session)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ClassroomNarrationCard(
                                speaking: session.player.currentBeat?.speaking ?? "",
                                progress: session.player.narrationProgress,
                                isPlaying: session.player.isPlaying
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: sideWidth)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)

                ClassroomTransportBar(
                    player: session.player,
                    isAsking: session.isAsking,
                    onAskNomi: { session.beginAsk() }
                )
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private var stageHeader: some View {
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
                    Text("Using \(lesson.sources.count) course \(lesson.sources.count == 1 ? "source" : "sources") ›")
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
    }

    private var nomiPose: NomiPose {
        if session.player.isSpeakingAnswer { return .talk }
        if session.isSendingAsk { return .thinking }
        if session.isListening { return .listening }
        if session.player.isPlaying { return .talk }
        return .idle
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
    let canRetry: Bool
    let onStart: (String) -> Void
    let onRetry: () -> Void

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
                VStack(alignment: .leading, spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    if canRetry {
                        Button("Try again", action: onRetry)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(NomiTheme.blue)
                    }
                }
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

private struct ClassroomNarrationCard: View {
    let speaking: String
    let progress: Double
    let isPlaying: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            Text(caption)
                .font(.body)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            NomiTheme.surface,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 1)
        }
        .accessibilityLabel("Nomi is saying")
        .accessibilityValue(speaking)
    }

    private var caption: AttributedString {
        var attributed = AttributedString(speaking)
        guard !speaking.isEmpty else { return attributed }

        let spoken = isPlaying || progress > 0.02
        if !spoken {
            attributed.foregroundColor = NomiTheme.secondaryInk
            return attributed
        }
        if progress >= 0.99 {
            attributed.foregroundColor = NomiTheme.blue
            return attributed
        }

        attributed.foregroundColor = NomiTheme.blue
        let cutoff = min(speaking.count, max(0, Int((progress * Double(speaking.count)).rounded(.down))))
        guard cutoff > 0, cutoff < speaking.count else { return attributed }
        let index = speaking.index(speaking.startIndex, offsetBy: cutoff)
        if let attrIndex = AttributedString.Index(index, within: attributed) {
            attributed[attrIndex...].foregroundColor = NomiTheme.secondaryInk
        }
        return attributed
    }
}

private struct ClassroomTransportBar: View {
    let player: ClassroomLessonPlayer
    var isAsking = false
    let onAskNomi: () -> Void

    var body: some View {
        HStack(spacing: 44) {
            control("Previous", enabled: player.canMoveBackward && !isAsking, action: player.moveBackward)
            control(playbackTitle, enabled: !isAsking, prominent: true, action: player.togglePlayback)
            control("Ask Nomi", enabled: !isAsking, action: onAskNomi)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var playbackTitle: String {
        switch player.playbackState {
        case .playing: "Pause"
        case .completed, .ready, .paused: "Continue"
        }
    }

    private func control(
        _ title: String,
        enabled: Bool = true,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? NomiTheme.blue : NomiTheme.ink)
                .opacity(enabled ? 1 : 0.35)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
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
