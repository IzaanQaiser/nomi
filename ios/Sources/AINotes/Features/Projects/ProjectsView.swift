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

    func delete(_ project: Project) async {
        do {
            try await APIClient.shared.deleteProject(id: project.id)
            projects.removeAll { $0.id == project.id }
            sourceCounts[project.id] = nil
        } catch {
            errorMessage = error.localizedDescription
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
            VStack(spacing: 0) {
                homeHeader

                if model.projects.isEmpty && !model.isLoading {
                    emptyState
                } else {
                    projectsState
                }
            }
            .background(NomiTheme.paper.ignoresSafeArea())
            .preferredColorScheme(.light)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Project.self) { project in
                ProjectShellView(project: project)
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
                    Task { await model.delete(project) }
                }
                Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
            } message: {
                Text("Its sources, notes, and saved files will be permanently removed.")
            }
        }
    }

    private var homeHeader: some View {
        HStack {
            Text("NOMI")
                .font(.headline.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(NomiTheme.ink)

            Spacer()

            Button {
                showingBackendSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NomiTheme.ink)
            .background(NomiTheme.surface.opacity(0.82), in: Circle())
            .overlay(Circle().stroke(NomiTheme.hairline, lineWidth: 0.75))
            .accessibilityLabel("Settings")
        }
        .frame(maxWidth: 1080)
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [NomiTheme.blue.opacity(0.14), NomiTheme.blue.opacity(0)],
                                center: .center,
                                startRadius: 24,
                                endRadius: 116
                            )
                        )
                        .frame(width: 240, height: 240)

                    Image("NomiIdle")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 104, height: 104)
                }
                .frame(height: 154)
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("A quieter way to learn.")
                        .font(.largeTitle.bold())
                        .foregroundStyle(NomiTheme.ink)
                        .accessibilityAddTraits(.isHeader)

                    Text("Create a project, add the material shaping your work,\nthen take notes with Nomi beside you.")
                        .font(.title3)
                        .foregroundStyle(NomiTheme.secondaryInk)
                        .multilineTextAlignment(.center)
                }

                newProjectButton
                    .controlSize(.large)
            }

            Spacer(minLength: 24)

            VStack(spacing: 8) {
                Text("N  O  M  I")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NomiTheme.secondaryInk.opacity(0.78))
                Text("Quiet intelligence. Warm presence.")
                    .font(.footnote)
                    .foregroundStyle(NomiTheme.secondaryInk.opacity(0.72))
            }
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectsState: some View {
        VStack(spacing: 16) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your projects")
                        .font(.largeTitle.bold())
                        .foregroundStyle(NomiTheme.ink)
                    Text("Pick up where you left off.")
                        .font(.body)
                        .foregroundStyle(NomiTheme.secondaryInk)
                }

                Spacer()

                newProjectButton
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 32)

            List {
                ForEach(model.projects) { project in
                    ProjectRow(
                        project: project,
                        sourceCount: model.sourceCounts[project.id]
                    ) {
                        path.append(project)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 24, bottom: 5, trailing: 24))
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

                addProjectRow
                    .listRowInsets(EdgeInsets(top: 7, leading: 24, bottom: 20, trailing: 24))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
        .padding(.top, 8)
    }

    private var newProjectButton: some View {
        Button {
            presentNewProject()
        } label: {
            Label("New Project", systemImage: "plus")
                .font(.headline)
                .padding(.horizontal, 10)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(NomiTheme.blue)
        .disabled(model.isCreating)
    }

    private var addProjectRow: some View {
        Button {
            presentNewProject()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(NomiTheme.blue)
                    .frame(width: 46, height: 46)
                    .background(NomiTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text("New Project")
                        .font(.headline)
                        .foregroundStyle(NomiTheme.ink)
                    Text("Add another course, research project, or anything you're learning.")
                        .font(.subheadline)
                        .foregroundStyle(NomiTheme.secondaryInk)
                }

                Spacer()
            }
            .padding(14)
            .frame(maxWidth: 980)
            .background(NomiTheme.surface.opacity(0.46), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        NomiTheme.secondaryInk.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
            HStack(spacing: 16) {
                Image(systemName: "folder.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(NomiTheme.blue)
                    .frame(width: 48, height: 48)
                    .background(NomiTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(NomiTheme.ink)
                        .lineLimit(1)

                    Group {
                        if let sourceCount {
                            Label(
                                "\(sourceCount) \(sourceCount == 1 ? "source" : "sources")",
                                systemImage: "books.vertical"
                            )
                        } else {
                            Label("Sources unavailable", systemImage: "books.vertical")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(NomiTheme.secondaryInk)
                }

                Spacer(minLength: 18)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.secondaryInk.opacity(0.75))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: 980, minHeight: 78)
            .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(NomiTheme.hairline, lineWidth: 0.75)
            }
            .shadow(color: NomiTheme.ink.opacity(0.045), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityHint("Opens the project notebook")
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
