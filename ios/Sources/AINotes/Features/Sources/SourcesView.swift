import SwiftUI
import UniformTypeIdentifiers

@Observable
final class SourcesViewModel {
    let project: Project
    var sources: [Source] = []
    var errorMessage: String?
    var isBusy = false

    init(project: Project) { self.project = project }

    func load() async {
        do { sources = try await APIClient.shared.listSources(projectId: project.id) }
        catch { errorMessage = error.localizedDescription }
    }

    func addText(title: String, content: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let s = try await APIClient.shared.addTextSource(
                projectId: project.id, title: title, content: content
            )
            sources.insert(s, at: 0)
            await pollUntilReady(id: s.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func addPDF(url: URL) async {
        isBusy = true
        defer { isBusy = false }
        // Security-scoped access is required for files from the document picker.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let s = try await APIClient.shared.uploadPDF(projectId: project.id, fileURL: url)
            sources.insert(s, at: 0)
            await pollUntilReady(id: s.id)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Ingestion used to run after the HTTP response; poll in case the server
    /// still returns `pending`. Stop as soon as the source is ready or failed.
    private func pollUntilReady(id: String) async {
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            await load()
            if let s = sources.first(where: { $0.id == id }),
               s.status == "ready" || s.status == "error" {
                return
            }
        }
    }
}

struct SourcesView: View {
    @State private var model: SourcesViewModel
    @State private var showTextEntry = false
    @State private var showPDFImporter = false
    @State private var draftTitle = ""
    @State private var draftContent = ""
    @Environment(\.dismiss) private var dismiss

    init(project: Project) {
        _model = State(initialValue: SourcesViewModel(project: project))
    }

    var body: some View {
        List {
            Section {
                Button {
                    draftTitle = ""; draftContent = ""; showTextEntry = true
                } label: { Label("Paste text", systemImage: "text.alignleft") }
                Button {
                    showPDFImporter = true
                } label: { Label("Upload PDF", systemImage: "doc.badge.plus") }
            } header: {
                Text("Add source")
            } footer: {
                Text("Sources are private to this notebook. The assistant only answers from them.")
            }

            Section("Sources") {
                if model.sources.isEmpty {
                    Text("No sources yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sources) { source in
                    HStack {
                        Image(systemName: source.kind == "pdf" ? "doc.fill" : "text.alignleft")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(source.title).lineLimit(1)
                            if let err = source.error, !err.isEmpty {
                                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                        Spacer()
                        StatusBadge(status: source.status)
                            .id("\(source.id)-\(source.status)")
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
            if model.isBusy {
                ToolbarItem(placement: .topBarLeading) { ProgressView() }
            }
        }
        .refreshable { await model.load() }
        .task {
            await model.load()
            while !Task.isCancelled {
                if model.sources.contains(where: { $0.status == "pending" }) {
                    await model.load()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .alert("Paste text", isPresented: $showTextEntry) {
            TextField("Title", text: $draftTitle)
            TextField("Content", text: $draftContent)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !content.isEmpty else { return }
                Task { await model.addText(title: title, content: content) }
            }
        }
        .fileImporter(
            isPresented: $showPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await model.addPDF(url: url) }
            }
        }
        .alert("Error", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct StatusBadge: View {
    let status: String

    var body: some View {
        switch status {
        case "ready":
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case "error":
            Label("Error", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:
            HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Processing") }
                .foregroundStyle(.secondary)
        }
    }
}
