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

    func addFiles(_ urls: [URL]) async {
        let supported = urls.filter { ["pdf", "docx", "png"].contains($0.pathExtension.lowercased()) }
        guard !supported.isEmpty else {
            errorMessage = "Choose .pdf, .docx, or .png files."
            return
        }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        var failures: [String] = []

        for url in supported.prefix(12) {
            // Each document-picker URL has its own security-scoped lifetime.
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let source = try await APIClient.shared.uploadSourceFile(
                    projectId: project.id,
                    fileURL: url
                )
                sources.removeAll { $0.id == source.id }
                sources.insert(source, at: 0)
                if source.status == "pending" { await pollUntilReady(id: source.id) }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func delete(_ source: Source) async {
        do {
            try await APIClient.shared.deleteSource(projectId: project.id, sourceId: source.id)
            if PDFNoteStore.selectedSourceID(projectId: project.id) == source.id {
                try? PDFNoteStore.removePDF(projectId: project.id)
            }
            sources.removeAll { $0.id == source.id }
        } catch {
            errorMessage = error.localizedDescription
        }
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
    @State private var showFileImporter = false
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
                    showFileImporter = true
                } label: { Label("Add files", systemImage: "doc.badge.plus") }
            } header: {
                Text("Add source")
            } footer: {
                Text("Supported files: .pdf, .docx, and .png. Select multiple files at once. Sources are private to this project and ground Nomi’s answers.")
            }

            Section("Sources") {
                if model.sources.isEmpty {
                    Text("No sources yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sources) { source in
                    HStack {
                        Image(systemName: sourceIcon(for: source.kind))
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await model.delete(source) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await model.delete(source) }
                        } label: {
                            Label("Delete Source", systemImage: "trash")
                        }
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
            isPresented: $showFileImporter,
            allowedContentTypes: supportedSourceTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await model.addFiles(urls) }
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .alert("Error", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var supportedSourceTypes: [UTType] {
        [.pdf, .png, UTType(filenameExtension: "docx")!]
    }

    private func sourceIcon(for kind: String) -> String {
        switch kind {
        case "png": "photo.fill"
        case "pdf", "docx": "doc.fill"
        default: "text.alignleft"
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
