import SwiftUI

@MainActor
@Observable
final class ProjectsViewModel {
    var projects: [Project] = []
    var sourceCounts: [String: Int] = [:]
    var isLoading = false
    var isCreating = false
    var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loadedProjects = try await APIClient.shared.listProjects()
            projects = loadedProjects
            errorMessage = nil
            await loadSourceCounts(for: loadedProjects)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(name: String) async -> Project? {
        isCreating = true
        defer { isCreating = false }
        do {
            let project = try await APIClient.shared.createProject(name: name)
            projects.insert(project, at: 0)
            sourceCounts[project.id] = 0
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func update(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
    }

    func delete(_ project: Project) async -> Bool {
        do {
            try await APIClient.shared.deleteProject(id: project.id)
            projects.removeAll { $0.id == project.id }
            sourceCounts[project.id] = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func loadSourceCounts(for projects: [Project]) async {
        let projectIDs = Set(projects.map(\.id))
        sourceCounts = sourceCounts.filter { projectIDs.contains($0.key) }

        await withTaskGroup(of: (String, Int?).self) { group in
            for project in projects {
                let projectID = project.id
                group.addTask {
                    do {
                        let sources = try await APIClient.shared.listSources(projectId: projectID)
                        return (projectID, sources.count)
                    } catch {
                        return (projectID, nil)
                    }
                }
            }

            for await (projectID, count) in group {
                if let count { sourceCounts[projectID] = count }
            }
        }
    }
}

struct ProjectsView: View {
    @State private var model = ProjectsViewModel()
    @State private var path: [Project]
    @State private var showingNew = false
    @State private var showingBackendSettings = false
    @State private var newName = ""
    @State private var projectPendingDeletion: Project?

    init(initialProject: Project? = nil) {
        _path = State(initialValue: initialProject.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { proxy in
                let sidebarWidth = proxy.size.width * 0.30

                HStack(spacing: 0) {
                    projectSidebar
                        .frame(width: sidebarWidth)

                    Rectangle()
                        .fill(NomiTheme.hairline)
                        .frame(width: 1)

                    mascotCanvas
                }
                .overlay(alignment: .topTrailing) {
                    settingsButton
                        .padding(24)
                }
            }
            .background(NomiTheme.paper.ignoresSafeArea())
            .preferredColorScheme(.light)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(
                    project: project,
                    onProjectUpdated: { updated in
                        model.update(updated)
                    },
                    onProjectDeleted: {
                        let didDelete = await model.delete(project)
                        if didDelete {
                            path.removeAll { $0.id == project.id }
                        }
                        return didDelete
                    }
                )
            }
            .overlay {
                if model.isLoading && model.projects.isEmpty {
                    ProgressView("Loading projects…")
                        .tint(NomiTheme.blue)
                        .foregroundStyle(NomiTheme.secondaryInk)
                } else if model.isCreating {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                    ProgressView("Creating project…")
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .sheet(isPresented: $showingBackendSettings) {
                BackendSettingsView {
                    Task { await model.load() }
                }
            }
            .alert("New Project", isPresented: $showingNew) {
                TextField("Course or project name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task {
                        if let project = await model.create(name: name) {
                            path.append(project)
                        }
                    }
                }
            } message: {
                Text("Each project keeps its sources, notes, and Nomi context together.")
            }
            .task { await model.load() }
            .alert(
                "Can't reach the backend",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text((model.errorMessage ?? "") + "\n\nOpen Backend Settings and verify the server URL.")
            }
            .confirmationDialog(
                "Delete \(projectPendingDeletion?.name ?? "this project")?",
                isPresented: Binding(
                    get: { projectPendingDeletion != nil },
                    set: { if !$0 { projectPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Project", role: .destructive) {
                    guard let project = projectPendingDeletion else { return }
                    projectPendingDeletion = nil
                    Task { _ = await model.delete(project) }
                }
                Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
            } message: {
                Text("Its sources, notes, and saved files will be permanently removed.")
            }
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader

            if model.projects.isEmpty && !model.isLoading {
                emptySidebar
            } else {
                projectList
            }
        }
        .background(NomiTheme.paper)
        .shadow(color: NomiTheme.ink.opacity(0.035), radius: 16, x: 6)
        .zIndex(1)
    }

    private var sidebarHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your projects")
                    .font(.title2.bold())
                    .foregroundStyle(NomiTheme.ink)
                    .accessibilityAddTraits(.isHeader)

                Text("Pick a project to get back to work.")
                    .font(.footnote)
                    .foregroundStyle(NomiTheme.secondaryInk)
            }

            Spacer(minLength: 8)

            if !model.projects.isEmpty {
                newProjectButton(compact: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var emptySidebar: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Text("A quieter way to learn.")
                    .font(.title2.bold())
                    .foregroundStyle(NomiTheme.ink)
                    .multilineTextAlignment(.center)

                Text("Create a project, add your course materials, then start taking notes and practicing.")
                    .font(.subheadline)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                newProjectButton(compact: false)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 30)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectList: some View {
        List {
            ForEach(model.projects) { project in
                ProjectRow(
                    project: project,
                    sourceCount: model.sourceCounts[project.id]
                ) {
                    path.append(project)
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        projectPendingDeletion = project
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        projectPendingDeletion = project
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private var mascotCanvas: some View {
        GeometryReader { proxy in
            let mascotSize = min(320, max(240, min(proxy.size.width, proxy.size.height) * 0.40))

            VStack(spacing: 26) {
                Image("NomiIdle")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: mascotSize, height: mascotSize)
                    .accessibilityHidden(true)

                Text("lets get this money")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(NomiTheme.ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .background(NomiTheme.surface)
    }

    private var settingsButton: some View {
        Button {
            showingBackendSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title2.weight(.semibold))
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
        .foregroundStyle(NomiTheme.ink)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(NomiTheme.ink.opacity(0.16), lineWidth: 1))
        .shadow(color: NomiTheme.ink.opacity(0.08), radius: 10, y: 4)
        .accessibilityLabel("Settings")
    }

    private func newProjectButton(compact: Bool) -> some View {
        Button {
            presentNewProject()
        } label: {
            Label("New Project", systemImage: "plus")
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .padding(.horizontal, compact ? 2 : 10)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: compact ? 11 : 14))
        .controlSize(compact ? .small : .large)
        .tint(NomiTheme.blue)
        .disabled(model.isCreating)
    }

    private func presentNewProject() {
        newName = ""
        showingNew = true
    }
}

private struct ProjectRow: View {
    let project: Project
    let sourceCount: Int?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(NomiTheme.ink)
                        .lineLimit(1)

                    Text(sourceSubtitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(NomiTheme.secondaryInk)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.secondaryInk.opacity(0.75))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(NomiTheme.hairline, lineWidth: 1)
            }
            .shadow(color: NomiTheme.ink.opacity(0.035), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the project")
    }

    private var sourceSubtitle: String {
        guard let sourceCount else { return "Loading sources…" }
        return "\(sourceCount) \(sourceCount == 1 ? "source" : "sources")"
    }
}

private struct BackendSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let onConnected: () -> Void

    @State private var urlString = AppConfig.configuredURLString
    @State private var statusMessage: String?
    @State private var isTesting = false
#if DEBUG
    @AppStorage("nomi.debugReplayOnboardingOnLaunch") private var replayOnboardingOnLaunch = false
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend URL") {
                    TextField("https://api.example.com", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Text("Use the stable HTTPS address of your deployed FastAPI backend. It is saved on this iPad, so changing servers does not require rebuilding the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let statusMessage {
                    Section("Status") {
                        Text(statusMessage)
                    }
                }

                Section {
                    Button {
                        saveAndTest()
                    } label: {
                        if isTesting {
                            HStack {
                                ProgressView()
                                Text("Testing…")
                            }
                        } else {
                            Text("Save and Test Connection")
                        }
                    }
                    .disabled(isTesting)
                }

#if DEBUG
                Section("Developer") {
                    Toggle("Replay onboarding on launch", isOn: $replayOnboardingOnLaunch)

                    Text("When enabled, force-quit and reopen Nomi to start from the first onboarding screen. Existing projects and backend data are kept.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
#endif
            }
            .navigationTitle("Backend Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func saveAndTest() {
        do {
            try AppConfig.saveBackendURL(urlString)
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        isTesting = true
        statusMessage = nil
        Task {
            do {
                statusMessage = try await APIClient.shared.checkHealth()
                onConnected()
            } catch {
                statusMessage = error.localizedDescription
            }
            isTesting = false
        }
    }
}
