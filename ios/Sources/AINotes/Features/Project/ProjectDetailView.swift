import SwiftUI

struct NotebookPageSource: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case projectPDF
    }

    let id: String
    let kind: Kind
    let title: String
}

struct ProjectNotebook: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    let createdAt: Date
    let pageSources: [NotebookPageSource]?

    static func primary(for project: Project) -> ProjectNotebook {
        ProjectNotebook(
            id: "primary",
            title: "Course Notebook",
            createdAt: project.createdAt,
            pageSources: nil
        )
    }

    func storageID(projectID: String) -> String {
        id == "primary" ? projectID : "\(projectID)-notebook-\(id)"
    }
}

private enum ProjectNotebookStore {
    private static func key(projectID: String) -> String {
        "nomi.projectNotebooks.\(projectID)"
    }

    static func load(for project: Project) -> [ProjectNotebook] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key(projectID: project.id)),
              let saved = try? JSONDecoder().decode([ProjectNotebook].self, from: data),
              !saved.isEmpty
        else {
            return [.primary(for: project)]
        }
        return saved
    }

    static func save(_ notebooks: [ProjectNotebook], projectID: String) {
        guard let data = try? JSONEncoder().encode(notebooks) else { return }
        UserDefaults.standard.set(data, forKey: key(projectID: projectID))
    }

    static func remove(project: Project, notebooks: [ProjectNotebook]) {
        for notebook in notebooks {
            PDFNoteStore.removeLocalNotebook(storageID: notebook.storageID(projectID: project.id))
        }
        UserDefaults.standard.removeObject(forKey: key(projectID: project.id))
    }
}

@MainActor
@Observable
private final class ProjectDetailModel {
    var project: Project
    var sources: [Source] = []
    var notebooks: [ProjectNotebook]
    var isLoading = false
    var isRenaming = false
    var errorMessage: String?

    init(project: Project) {
        self.project = project
        notebooks = ProjectNotebookStore.load(for: project)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let refreshedProject = APIClient.shared.getProject(id: project.id)
            async let refreshedSources = APIClient.shared.listSources(projectId: project.id)
            project = try await refreshedProject
            sources = try await refreshedSources
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addNotebook(title: String, sourceIDs: [String]) async throws -> ProjectNotebook {
        let selectedSources = sourceIDs.compactMap { id in
            sources.first { $0.id == id && $0.kind == "pdf" && $0.status == "ready" }
        }
        let notebook = ProjectNotebook(
            id: UUID().uuidString.lowercased(),
            title: title,
            createdAt: .now,
            pageSources: selectedSources
                .map {
                    NotebookPageSource(id: $0.id, kind: .projectPDF, title: $0.title)
                }
        )

        if !selectedSources.isEmpty {
            var documents: [(title: String, data: Data)] = []
            for source in selectedSources {
                let data = try await APIClient.shared.downloadSourcePDF(
                    projectId: project.id,
                    sourceId: source.id
                )
                documents.append((source.title, data))
            }
            try PDFNoteStore.importPDFs(
                documents,
                storageID: notebook.storageID(projectID: project.id)
            )
        }

        notebooks.append(notebook)
        ProjectNotebookStore.save(notebooks, projectID: project.id)
        return notebook
    }

    func renameNotebook(_ notebook: ProjectNotebook, to title: String) {
        guard let index = notebooks.firstIndex(where: { $0.id == notebook.id }) else { return }
        notebooks[index].title = title
        ProjectNotebookStore.save(notebooks, projectID: project.id)
    }

    func deleteNotebook(_ notebook: ProjectNotebook) {
        guard notebooks.count > 1,
              notebooks.contains(where: { $0.id == notebook.id })
        else { return }

        PDFNoteStore.removeLocalNotebook(
            storageID: notebook.storageID(projectID: project.id)
        )
        notebooks.removeAll { $0.id == notebook.id }
        ProjectNotebookStore.save(notebooks, projectID: project.id)
    }

    /// Generate an exam from the project's sources, render it to a PDF, and add
    /// it as a new (exam) notebook whose background is that PDF.
    func generateExamNotebook() async throws -> ProjectNotebook {
        let exam = try await APIClient.shared.generateExam(projectId: project.id)
        let pdf = ExamPDFRenderer.makePDF(from: exam)
        let notebook = ProjectNotebook(
            id: UUID().uuidString.lowercased(),
            title: exam.title,
            createdAt: .now,
            pageSources: nil
        )
        let storageID = notebook.storageID(projectID: project.id)
        try PDFNoteStore.importPDFs([(exam.title, pdf)], storageID: storageID)
        ExamStore.save(exam, storageID: storageID)
        notebooks.append(notebook)
        ProjectNotebookStore.save(notebooks, projectID: project.id)
        return notebook
    }

    func renameProject(to name: String) async -> Project? {
        isRenaming = true
        defer { isRenaming = false }
        do {
            project = try await APIClient.shared.updateProject(id: project.id, name: name)
            errorMessage = nil
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func forgetLocalNotebooks() {
        ProjectNotebookStore.remove(project: project, notebooks: notebooks)
    }
}

/// The landing surface for a single project. It keeps project context visible
/// while making notebooks the primary object, instead of opening a canvas
/// before the student has chosen what they want to work on.
struct ProjectDetailView: View {
    let onProjectUpdated: (Project) -> Void
    let onProjectDeleted: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectDetailModel
    @State private var showSources = false
    @State private var showSettings = false
    @State private var showNewNotebook = false
    @State private var showRename = false
    @State private var showDetails = false
    @State private var showDeleteConfirmation = false
    @State private var projectName = ""
    @State private var isDeleting = false
    @State private var isGeneratingExam = false
    @State private var notebookForInfo: ProjectNotebook?
    @State private var notebookPendingRename: ProjectNotebook?
    @State private var notebookPendingDeletion: ProjectNotebook?
    @State private var notebookName = ""
    @State private var notebookToOpen: ProjectNotebook?
    @State private var pendingCreatedNotebook: ProjectNotebook?

    init(
        project: Project,
        onProjectUpdated: @escaping (Project) -> Void,
        onProjectDeleted: @escaping () async -> Bool
    ) {
        _model = State(initialValue: ProjectDetailModel(project: project))
        self.onProjectUpdated = onProjectUpdated
        self.onProjectDeleted = onProjectDeleted
    }

    var body: some View {
        GeometryReader { proxy in
            let sidebarWidth = min(430, max(350, proxy.size.width * 0.34))

            HStack(spacing: 0) {
                projectSidebar
                    .frame(width: sidebarWidth)

                Rectangle()
                    .fill(NomiTheme.hairline)
                    .frame(width: 1)

                notebooksPanel
            }
        }
        .background(NomiTheme.paper.ignoresSafeArea())
        .preferredColorScheme(.light)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $notebookToOpen) { notebook in
            ProjectShellView(project: model.project, notebook: notebook)
        }
        .fullScreenCover(isPresented: $isGeneratingExam) {
            ExamLoadingView()
        }
        .task {
            await model.load()
            onProjectUpdated(model.project)
        }
        .sheet(isPresented: $showSources, onDismiss: {
            Task { await model.load() }
        }) {
            NavigationStack {
                SourcesView(project: model.project)
            }
        }
        .sheet(isPresented: $showDetails) {
            ProjectDetailsSheet(
                project: model.project,
                sourceCount: model.sources.count,
                notebookCount: model.notebooks.count
            )
        }
        .sheet(item: $notebookForInfo) { notebook in
            NotebookInfoSheet(projectID: model.project.id, notebook: notebook)
        }
        .alert(
            "Rename Notebook",
            isPresented: Binding(
                get: { notebookPendingRename != nil },
                set: { if !$0 { notebookPendingRename = nil } }
            )
        ) {
            TextField("Notebook name", text: $notebookName)
            Button("Cancel", role: .cancel) { notebookPendingRename = nil }
            Button("Save") {
                let title = notebookName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let notebook = notebookPendingRename, !title.isEmpty else { return }
                model.renameNotebook(notebook, to: title)
                notebookPendingRename = nil
            }
        } message: {
            Text("Choose a name that makes this notebook easy to find.")
        }
        .confirmationDialog(
            "Delete \(notebookPendingDeletion?.title ?? "this notebook")?",
            isPresented: Binding(
                get: { notebookPendingDeletion != nil },
                set: { if !$0 { notebookPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Notebook", role: .destructive) {
                guard let notebook = notebookPendingDeletion else { return }
                model.deleteNotebook(notebook)
                notebookPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { notebookPendingDeletion = nil }
        } message: {
            Text("Its pages, ink, and pasted images will be permanently removed.")
        }
        .sheet(isPresented: $showNewNotebook, onDismiss: {
            guard let notebook = pendingCreatedNotebook else { return }
            pendingCreatedNotebook = nil
            Task { @MainActor in
                await Task.yield()
                notebookToOpen = notebook
            }
        }) {
            NewNotebookSheet(
                projectName: model.project.name,
                sources: readyPDFSources,
                onCreate: { title, sourceIDs in
                    pendingCreatedNotebook = try await model.addNotebook(
                        title: title,
                        sourceIDs: sourceIDs
                    )
                }
            )
        }
        .alert("Rename Project", isPresented: $showRename) {
            TextField("Project name", text: $projectName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    if let updated = await model.renameProject(to: name) {
                        onProjectUpdated(updated)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete \(model.project.name)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                isDeleting = true
                Task {
                    if await onProjectDeleted() {
                        model.forgetLocalNotebooks()
                    } else {
                        isDeleting = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sources and notebooks will be permanently removed.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay {
            if isDeleting || model.isRenaming {
                Color.black.opacity(0.06).ignoresSafeArea()
                ProgressView(isDeleting ? "Deleting project…" : "Renaming project…")
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            projectHeader

            ScrollView {
                VStack(spacing: 18) {
                    contextCard
                    examPrepCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(NomiTheme.paper)
    }

    private var projectHeader: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.bold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NomiTheme.ink)
            .background(NomiTheme.surface, in: Circle())
            .overlay(Circle().stroke(NomiTheme.hairline, lineWidth: 1))
            .accessibilityLabel("Back to projects")

            VStack(alignment: .leading, spacing: 4) {
                Text(model.project.name)
                    .font(.title2.bold())
                    .foregroundStyle(NomiTheme.ink)
                    .lineLimit(2)

                Text(projectSummary)
                    .font(.footnote)
                    .foregroundStyle(NomiTheme.secondaryInk)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Context")
                        .font(.title3.bold())
                        .foregroundStyle(NomiTheme.ink)
                    Text("What Nomi knows about this project")
                        .font(.caption)
                        .foregroundStyle(NomiTheme.secondaryInk)
                }

                Spacer()

                Button("Manage") { showSources = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.blue)
            }

            if model.isLoading && model.sources.isEmpty {
                ProgressView("Loading context…")
                    .frame(maxWidth: .infinity, minHeight: 118)
            } else {
                VStack(spacing: 12) {
                    if model.sources.isEmpty {
                        Text("No sources yet. Add the first thing Nomi should know.")
                            .font(.subheadline)
                            .foregroundStyle(NomiTheme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(model.sources.prefix(2)) { source in
                            ContextSourceRow(source: source)
                        }
                    }

                    Button { showSources = true } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(NomiTheme.blue, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add source")
                }
            }
        }
        .padding(18)
        .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 1)
        }
    }

    private var examPrepCard: some View {
        Button {
            startExamPrep()
        } label: {
            HStack(spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(NomiTheme.blue.opacity(0.14))
                        .frame(width: 58, height: 58)
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(NomiTheme.blue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Exam Prep")
                        .font(.headline)
                        .foregroundStyle(NomiTheme.ink)
                    Text("I’ll build a likely exam from your notes, past exams and assignments — then grade it when time’s up.")
                        .font(.subheadline)
                        .foregroundStyle(NomiTheme.secondaryInk)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.secondaryInk)
            }
            .padding(18)
            .background(NomiTheme.blue.opacity(0.065), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isLoading)
    }

    private func startExamPrep() {
        guard !isGeneratingExam else { return }
        isGeneratingExam = true
        Task {
            do {
                let notebook = try await model.generateExamNotebook()
                isGeneratingExam = false
                notebookToOpen = notebook
            } catch {
                isGeneratingExam = false
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var notebooksPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Notebooks")
                        .font(.system(size: 38, weight: .bold))
                        .tracking(-0.7)
                        .foregroundStyle(NomiTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your thinking, organized inside this project.")
                        .font(.title3)
                        .foregroundStyle(NomiTheme.secondaryInk)
                }

                Spacer()

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NomiTheme.ink)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(NomiTheme.ink.opacity(0.14), lineWidth: 1))
                .shadow(color: NomiTheme.ink.opacity(0.07), radius: 10, y: 4)
                .accessibilityLabel("Project settings")
                .popover(isPresented: $showSettings, arrowEdge: .top) {
                    ProjectSettingsMenu(
                        project: model.project,
                        sourceCount: model.sources.count,
                        notebookCount: model.notebooks.count,
                        onManageContext: {
                            showSettings = false
                            showSources = true
                        },
                        onRename: {
                            projectName = model.project.name
                            showSettings = false
                            showRename = true
                        },
                        onShowDetails: {
                            showSettings = false
                            showDetails = true
                        },
                        onDelete: {
                            showSettings = false
                            showDeleteConfirmation = true
                        }
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }
            .padding(.horizontal, 38)
            .padding(.top, 34)
            .padding(.bottom, 26)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 285, maximum: 390), spacing: 20)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(model.notebooks) { notebook in
                        NavigationLink {
                            ProjectShellView(project: model.project, notebook: notebook)
                        } label: {
                            NotebookCard(projectID: model.project.id, notebook: notebook)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                notebookName = notebook.title
                                notebookPendingRename = notebook
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

                            Button {
                                notebookForInfo = notebook
                            } label: {
                                Label("Notebook Info", systemImage: "info.circle")
                            }

                            Divider()

                            Button(role: .destructive) {
                                notebookPendingDeletion = notebook
                            } label: {
                                Label("Delete Notebook", systemImage: "trash")
                            }
                            .disabled(model.notebooks.count == 1)
                        }
                    }

                    Button {
                        pendingCreatedNotebook = nil
                        showNewNotebook = true
                    } label: {
                        NewNotebookCard()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 38)
                .padding(.bottom, 38)
            }
        }
        .background(NomiTheme.surface)
    }

    private var projectSummary: String {
        "\(model.notebooks.count) \(model.notebooks.count == 1 ? "notebook" : "notebooks")  •  \(model.sources.count) \(model.sources.count == 1 ? "source" : "sources")"
    }

    private var readyPDFSources: [Source] {
        model.sources.filter { $0.kind == "pdf" && $0.status == "ready" }
    }
}

private struct ContextSourceRow: View {
    let source: Source

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(source.kind == "pdf" ? Color.red.opacity(0.09) : NomiTheme.blue.opacity(0.09))
                Image(systemName: source.kind == "pdf" ? "doc.fill" : "text.alignleft")
                    .font(.title2)
                    .foregroundStyle(source.kind == "pdf" ? Color.red : NomiTheme.blue)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(detailColor)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        switch source.status {
        case "ready":
            return "Added \(source.createdAt.formatted(.relative(presentation: .named)))"
        case "error":
            return "Needs attention"
        default:
            return "Processing…"
        }
    }

    private var detailColor: Color {
        source.status == "error" ? .red : NomiTheme.secondaryInk
    }
}

private struct NotebookCard: View {
    let projectID: String
    let notebook: ProjectNotebook

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "book.closed.fill")
                .font(.title2)
                .foregroundStyle(NomiTheme.blue)
                .frame(width: 56, height: 56)
                .background(NomiTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))

            VStack(alignment: .leading, spacing: 5) {
                Text(notebook.title)
                    .font(.headline)
                    .foregroundStyle(NomiTheme.ink)
                    .lineLimit(2)
                Text(notebookSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(NomiTheme.secondaryInk)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.headline.weight(.semibold))
                .foregroundStyle(NomiTheme.secondaryInk.opacity(0.72))
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(NomiTheme.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 1)
        }
        .shadow(color: NomiTheme.ink.opacity(0.035), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHint("Opens this notebook")
    }

    private var notebookSubtitle: String {
        if let count = notebook.pageSources?.count, count > 0 {
            return "\(count) context \(count == 1 ? "source" : "sources") included"
        }
        if PDFNoteStore.hasPDF(projectId: notebook.storageID(projectID: projectID)) {
            return "PDF-backed notebook"
        }
        return "Blank canvas"
    }
}

private struct NewNotebookCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.title2.weight(.medium))
                .foregroundStyle(NomiTheme.blue)
                .frame(width: 48, height: 48)
                .background(NomiTheme.blue.opacity(0.09), in: Circle())
            Text("New Notebook")
                .font(.headline)
                .foregroundStyle(NomiTheme.ink)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(NomiTheme.blue.opacity(0.025), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(NomiTheme.blue.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [7]))
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct NewNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss

    let projectName: String
    let sources: [Source]
    let onCreate: (String, [String]) async throws -> Void

    @State private var title = ""
    @State private var selectedSourceIDs: Set<String> = []
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        NomiView(pose: .idle)
                            .frame(width: 58, height: 58)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start with what matters.")
                                .font(.headline)
                            Text("Make a blank notebook or bring in pages from \(projectName).")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                }

                Section("Notebook") {
                    TextField("e.g. Lecture Notes", text: $title)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }

                Section {
                    if sources.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.badge.plus")
                                .font(.title2)
                                .foregroundStyle(NomiTheme.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("No PDF context yet")
                                    .font(.headline)
                                Text("This notebook will begin with a blank page. You can add a PDF later from its page settings.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                    } else {
                        ForEach(sources) { source in
                            Button {
                                toggle(source.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.fill")
                                        .foregroundStyle(.red)
                                        .frame(width: 28, height: 28)
                                        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

                                    Text(source.title)
                                        .foregroundStyle(NomiTheme.ink)
                                        .lineLimit(2)

                                    Spacer()

                                    Image(systemName: selectedSourceIDs.contains(source.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedSourceIDs.contains(source.id) ? NomiTheme.blue : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack {
                        Text("Starting Pages")
                        Spacer()
                        if !sources.isEmpty {
                            Button(selectedSourceIDs.count == sources.count ? "Clear" : "Select All") {
                                if selectedSourceIDs.count == sources.count {
                                    selectedSourceIDs.removeAll()
                                } else {
                                    selectedSourceIDs = Set(sources.map(\.id))
                                }
                            }
                            .textCase(nil)
                        }
                    }
                } footer: {
                    Text("Selected PDFs are copied into the notebook in the order shown. The notebook keeps those pages even if a source is later removed from the project.")
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isCreating)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        createNotebook()
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NomiTheme.blue)
                    .disabled(normalizedTitle.isEmpty || isCreating)
                    .accessibilityLabel("Create notebook")
                }
            }
            .alert(
                "Couldn’t create notebook",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isCreating)
    }

    private func toggle(_ sourceID: String) {
        if selectedSourceIDs.contains(sourceID) {
            selectedSourceIDs.remove(sourceID)
        } else {
            selectedSourceIDs.insert(sourceID)
        }
    }

    private func createNotebook() {
        let orderedSelection = sources
            .filter { selectedSourceIDs.contains($0.id) }
            .map(\.id)
        isCreating = true
        Task {
            do {
                try await onCreate(normalizedTitle, orderedSelection)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

private struct NotebookInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    let projectID: String
    let notebook: ProjectNotebook

    private var hasPDFPages: Bool {
        PDFNoteStore.hasPDF(projectId: notebook.storageID(projectID: projectID))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "book.closed.fill")
                            .font(.title2)
                            .foregroundStyle(NomiTheme.blue)
                            .frame(width: 52, height: 52)
                            .background(NomiTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(notebook.title)
                                .font(.headline)
                            Text(hasPDFPages ? "PDF-backed notebook" : "Paper notebook")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Details") {
                    LabeledContent(
                        "Created",
                        value: notebook.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    LabeledContent(
                        "Starting context",
                        value: "\(notebook.pageSources?.count ?? 0)"
                    )
                }

                if let pageSources = notebook.pageSources, !pageSources.isEmpty {
                    Section("Pages From Project Context") {
                        ForEach(pageSources) { source in
                            Label(source.title, systemImage: "doc.fill")
                                .lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle("Notebook Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ProjectSettingsMenu: View {
    let project: Project
    let sourceCount: Int
    let notebookCount: Int
    let onManageContext: () -> Void
    let onRename: () -> Void
    let onShowDetails: () -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 13) {
                        NomiView(pose: .idle)
                            .frame(width: 52, height: 52)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.headline)
                                .foregroundStyle(NomiTheme.ink)
                            Text("\(notebookCount) \(notebookCount == 1 ? "notebook" : "notebooks") • \(sourceCount) \(sourceCount == 1 ? "source" : "sources")")
                                .font(.footnote)
                                .foregroundStyle(NomiTheme.secondaryInk)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Project") {
                    settingsButton("Manage Context", systemImage: "square.stack.3d.up", action: onManageContext)
                    settingsButton("Rename Project", systemImage: "pencil", action: onRename)
                    settingsButton("Project Details", systemImage: "info.circle", action: onShowDetails)
                }

                Section {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Project", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Project Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(width: 390, height: 430)
    }

    private func settingsButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(NomiTheme.ink)
    }
}

private struct ProjectDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let sourceCount: Int
    let notebookCount: Int

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    LabeledContent("Name", value: project.name)
                    LabeledContent("Created", value: project.createdAt.formatted(date: .abbreviated, time: .omitted))
                }

                Section("Contents") {
                    LabeledContent("Notebooks", value: "\(notebookCount)")
                    LabeledContent("Sources", value: "\(sourceCount)")
                }
            }
            .navigationTitle("Project Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
