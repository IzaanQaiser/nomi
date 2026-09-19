import SwiftUI

@Observable
final class ProjectsViewModel {
    var projects: [Project] = []
    var isLoading = false
    var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await APIClient.shared.listProjects()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(name: String) async -> Project? {
        do {
            let project = try await APIClient.shared.createProject(name: name)
            projects.insert(project, at: 0)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ProjectsView: View {
    @State private var model = ProjectsViewModel()
    @State private var showingNew = false
    @State private var showingBackendSettings = false
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 20)]

    var body: some View {
        NavigationStack {
            Group {
                if model.projects.isEmpty && !model.isLoading {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.projects) { project in
                                NavigationLink(value: project) {
                                    ProjectCard(project: project)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await model.delete(project) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("Notebooks")
            .navigationDestination(for: Project.self) { project in
                ProjectShellView(project: project)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingBackendSettings = true
                    } label: { Label("Backend Settings", systemImage: "server.rack") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newName = ""
                        showingNew = true
                    } label: { Label("New Notebook", systemImage: "plus") }
                }
            }
            .overlay { if model.isLoading { ProgressView() } }
            .sheet(isPresented: $showingBackendSettings) {
                BackendSettingsView {
                    Task { await model.load() }
                }
            }
            .alert("New Notebook", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { _ = await model.create(name: name) }
                }
            } message: {
                Text("Each notebook keeps its own sources and context.")
            }
            .task { await model.load() }
            .refreshable { await model.load() }
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
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No notebooks yet", systemImage: "books.vertical")
        } description: {
            Text("Create a notebook, add your course sources, then take notes and ask questions.")
        } actions: {
            Button("Create Notebook") {
                newName = ""
                showingNew = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct ProjectCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "book.closed.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text(project.name)
                .font(.headline)
                .lineLimit(2)
            Text(project.createdAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct BackendSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let onConnected: () -> Void

    @State private var urlString = AppConfig.configuredURLString
    @State private var statusMessage: String?
    @State private var isTesting = false

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
