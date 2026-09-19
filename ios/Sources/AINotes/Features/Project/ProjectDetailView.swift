import SwiftUI

struct ProjectNotebook: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    let createdAt: Date

    static func primary(for project: Project) -> ProjectNotebook {
        ProjectNotebook(id: "primary", title: "Course Notebook", createdAt: project.createdAt)
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

    func addNotebook(title: String) {
        let notebook = ProjectNotebook(
            id: UUID().uuidString.lowercased(),
            title: title,
            createdAt: .now
        )
        notebooks.append(notebook)
        ProjectNotebookStore.save(notebooks, projectID: project.id)
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
    @State private var notebookName = ""
    @State private var projectName = ""
    @State private var isDeleting = false

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
        .alert("New Notebook", isPresented: $showNewNotebook) {
            TextField("Notebook name", text: $notebookName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let title = notebookName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                model.addNotebook(title: title)
            }
        } message: {
            Text("Give this notebook a clear name, like Lecture Notes or Midterm Practice.")
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
                    nomiCard
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
            } else if model.sources.isEmpty {
                Button { showSources = true } label: {
                    VStack(spacing: 9) {
                        Image(systemName: "doc.badge.plus")
                            .font(.title2)
                        Text("Add your first source")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(NomiTheme.blue)
                    .frame(maxWidth: .infinity, minHeight: 118)
                    .background(NomiTheme.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(NomiTheme.blue.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [6]))
                    }
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(model.sources.prefix(4)) { source in
                            SourcePreviewCard(source: source)
                        }

                        Button { showSources = true } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.title2.weight(.medium))
                                Text("Add Source")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(NomiTheme.blue)
                            .frame(width: 116, height: 126)
                            .background(NomiTheme.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(NomiTheme.blue.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5]))
                            }
                        }
                        .buttonStyle(.plain)
                    }
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

    private var nomiCard: some View {
        HStack(spacing: 15) {
            Image("NomiIdle")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Ready when you are.")
                    .font(.headline)
                    .foregroundStyle(NomiTheme.ink)
                Text("Open a notebook and I’ll stay with the work.")
                    .font(.subheadline)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(NomiTheme.blue.opacity(0.065), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                            NotebookCard(notebook: notebook)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        notebookName = ""
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
}

private struct SourcePreviewCard: View {
    let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(source.kind == "pdf" ? Color.red.opacity(0.09) : NomiTheme.blue.opacity(0.09))
                Image(systemName: source.kind == "pdf" ? "doc.fill" : "text.alignleft")
                    .font(.title2)
                    .foregroundStyle(source.kind == "pdf" ? Color.red : NomiTheme.blue)
            }
            .frame(width: 42, height: 42)

            Text(source.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomiTheme.ink)
                .lineLimit(2)

            Text(source.status == "ready" ? "Ready" : "Processing")
                .font(.caption2)
                .foregroundStyle(source.status == "ready" ? Color.green : NomiTheme.secondaryInk)
        }
        .frame(width: 116, height: 126, alignment: .topLeading)
        .padding(12)
        .background(NomiTheme.paper, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 1)
        }
    }
}

private struct NotebookCard: View {
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
                Text("Open notebook")
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
            Text("Start a fresh canvas")
                .font(.subheadline)
                .foregroundStyle(NomiTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(NomiTheme.blue.opacity(0.025), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(NomiTheme.blue.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [7]))
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
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
                        Image("NomiIdle")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
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
                    }
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
