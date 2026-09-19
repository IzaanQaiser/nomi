import SwiftUI
import UniformTypeIdentifiers

private struct CourseMaterialItem: Identifiable, Equatable {
    enum Phase: Equatable {
        case uploading
        case ready
        case failed(String)
        case deleting

        var isBusy: Bool {
            self == .uploading || self == .deleting
        }
    }

    let id: UUID
    var sourceID: String?
    var title: String
    var byteCount: Int?
    var phase: Phase

    init(
        id: UUID = UUID(),
        sourceID: String? = nil,
        title: String,
        byteCount: Int? = nil,
        phase: Phase
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.byteCount = byteCount
        self.phase = phase
    }
}
@MainActor
@Observable
private final class CourseContextModel {
    let project: Project
    var materials: [CourseMaterialItem] = []
    var errorMessage: String?
    var isLoading = false
    var notebookSourceID: String?
    var notebookSelectionInFlight: String?

    private var hasLoaded = false

    init(project: Project) {
        self.project = project
        notebookSourceID = PDFNoteStore.selectedSourceID(projectId: project.id)
    }

    var hasBusyMaterials: Bool {
        materials.contains { $0.phase.isBusy } || notebookSelectionInFlight != nil
    }

    var canContinue: Bool {
        materials.contains { $0.phase == .ready } && !hasBusyMaterials
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        defer { isLoading = false }

        do {
            let sources = try await APIClient.shared.listSources(projectId: project.id)
            materials = sources.map(material(from:))
            if let notebookSourceID,
               !sources.contains(where: { $0.id == notebookSourceID }) {
                try? PDFNoteStore.removePDF(projectId: project.id)
                self.notebookSourceID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPDFs(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else {
            errorMessage = "Choose one or more PDF files."
            return
        }

        errorMessage = nil
        for url in pdfs.prefix(12) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let item = CourseMaterialItem(
                title: url.lastPathComponent,
                byteCount: values?.fileSize,
                phase: .uploading
            )
            materials.append(item)
            Task { await upload(url: url, itemID: item.id) }
        }
    }

    func remove(_ item: CourseMaterialItem) async {
        guard !item.phase.isBusy else { return }
        guard let index = materials.firstIndex(where: { $0.id == item.id }) else { return }

        guard let sourceID = item.sourceID else {
            materials.remove(at: index)
            return
        }

        let previousPhase = materials[index].phase
        materials[index].phase = .deleting
        do {
            try await APIClient.shared.deleteSource(projectId: project.id, sourceId: sourceID)
            if notebookSourceID == sourceID {
                try? PDFNoteStore.removePDF(projectId: project.id)
                notebookSourceID = nil
            }
            materials.removeAll { $0.id == item.id }
        } catch {
            if let currentIndex = materials.firstIndex(where: { $0.id == item.id }) {
                materials[currentIndex].phase = previousPhase
            }
            errorMessage = error.localizedDescription
        }
    }

    func toggleNotebook(_ item: CourseMaterialItem) async {
        guard item.phase == .ready, let sourceID = item.sourceID else { return }
        guard notebookSelectionInFlight == nil else { return }

        notebookSelectionInFlight = sourceID
        defer { notebookSelectionInFlight = nil }
        errorMessage = nil

        do {
            if notebookSourceID == sourceID {
                try PDFNoteStore.removePDF(projectId: project.id)
                notebookSourceID = nil
            } else {
                let data = try await APIClient.shared.downloadSourcePDF(
                    projectId: project.id,
                    sourceId: sourceID
                )
                try PDFNoteStore.importPDF(
                    data: data,
                    projectId: project.id,
                    sourceId: sourceID
                )
                notebookSourceID = sourceID
            }
        } catch {
            errorMessage = "Couldn’t prepare this PDF for writing. \(error.localizedDescription)"
        }
    }

    private func upload(url: URL, itemID: UUID) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let source = try await APIClient.shared.uploadPDF(projectId: project.id, fileURL: url)
            apply(source: source, to: itemID)
            if source.status == "pending" {
                await poll(sourceID: source.id, itemID: itemID)
            }
        } catch {
            update(itemID: itemID, phase: .failed(error.localizedDescription))
        }
    }

    private func poll(sourceID: String, itemID: UUID) async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(700))
            do {
                let sources = try await APIClient.shared.listSources(projectId: project.id)
                guard let source = sources.first(where: { $0.id == sourceID }) else { return }
                apply(source: source, to: itemID)
                if source.status == "ready" || source.status == "error" { return }
            } catch {
                update(itemID: itemID, phase: .failed(error.localizedDescription))
                return
            }
        }
        update(itemID: itemID, phase: .failed("This PDF is taking longer than expected. Try adding it again."))
    }

    private func material(from source: Source) -> CourseMaterialItem {
        CourseMaterialItem(
            sourceID: source.id,
            title: source.title,
            phase: phase(for: source)
        )
    }

    private func apply(source: Source, to itemID: UUID) {
        guard let index = materials.firstIndex(where: { $0.id == itemID }) else { return }
        materials[index].sourceID = source.id
        materials[index].title = source.title
        materials[index].phase = phase(for: source)
    }

    private func phase(for source: Source) -> CourseMaterialItem.Phase {
        switch source.status {
        case "ready": .ready
        case "error": .failed(source.error ?? "Nomi couldn't read this PDF.")
        default: .uploading
        }
    }

    private func update(itemID: UUID, phase: CourseMaterialItem.Phase) {
        guard let index = materials.firstIndex(where: { $0.id == itemID }) else { return }
        materials[index].phase = phase
    }
}

/// Onboarding step two: give the newly-created course its initial grounding.
/// Only formats supported by the backend are advertised and accepted.
struct CourseContextView: View {
    let onCompleted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: CourseContextModel
    @State private var showImporter = false
    @State private var isFinishing = false

    init(project: Project, onCompleted: @escaping () -> Void) {
        _model = State(initialValue: CourseContextModel(project: project))
        self.onCompleted = onCompleted
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 700

            VStack(spacing: 0) {
                Spacer(minLength: compact ? 18 : 42)

                VStack(spacing: compact ? 16 : 24) {
                    hero(compact: compact)
                    materialsArea(compact: compact)
                    footer
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 34)

                Spacer(minLength: compact ? 18 : 42)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NomiTheme.paper.ignoresSafeArea())
        .preferredColorScheme(.light)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls): model.addPDFs(urls)
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .task { await model.load() }
    }

    private func hero(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            VStack(spacing: compact ? 5 : 7) {
                Image(mascotAsset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: compact ? 62 : 86, height: compact ? 62 : 86)
                    .id(mascotAsset)
                    .transition(.opacity)
                    .accessibilityHidden(true)

                Text(model.project.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(NomiTheme.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(NomiTheme.blue.opacity(0.09), in: Capsule())
            }

            Text("Show me what your class is using.")
                .font(.system(size: compact ? 28 : 34, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(NomiTheme.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("Add the PDFs that shape this course—slides, readings, assignments, or past exams.")
                .font(.system(size: compact ? 15 : 17))
                .foregroundStyle(NomiTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
        }
        .animation(.easeInOut(duration: 0.2), value: mascotAsset)
    }

    @ViewBuilder
    private func materialsArea(compact: Bool) -> some View {
        if model.materials.isEmpty && !model.isLoading {
            Button { showImporter = true } label: {
                VStack(spacing: compact ? 8 : 12) {
                    Image(systemName: "plus")
                        .font(.system(size: compact ? 24 : 30, weight: .medium))
                        .foregroundStyle(NomiTheme.blue)
                        .frame(width: compact ? 50 : 62, height: compact ? 50 : 62)
                        .background(NomiTheme.blue.opacity(0.09), in: Circle())

                    VStack(spacing: 3) {
                        Text("Add course PDFs")
                            .font(.headline)
                            .foregroundStyle(NomiTheme.ink)
                        Text("Choose one or several files")
                            .font(.subheadline)
                            .foregroundStyle(NomiTheme.secondaryInk)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 138 : 176)
                .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            NomiTheme.blue.opacity(0.48),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                        )
                }
                .shadow(color: NomiTheme.ink.opacity(0.05), radius: 16, y: 6)
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                model.addPDFs(pdfs)
                return !pdfs.isEmpty
            }
            .transition(.opacity)
        } else {
            VStack(spacing: 0) {
                if model.isLoading {
                    ProgressView("Checking your course…")
                        .tint(NomiTheme.blue)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.materials) { item in
                                MaterialRow(
                                    item: item,
                                    isNotebookSource: model.notebookSourceID == item.sourceID,
                                    isChangingNotebook: model.notebookSelectionInFlight == item.sourceID,
                                    onToggleNotebook: { Task { await model.toggleNotebook(item) } },
                                    onRemove: { Task { await model.remove(item) } }
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))

                                if item.id != model.materials.last?.id {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: compact ? 176 : 238)
                }

                Divider()

                Button { showImporter = true } label: {
                    Label("Add more PDFs", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NomiTheme.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .disabled(model.hasBusyMaterials)
            }
            .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(NomiTheme.hairline, lineWidth: 1)
            }
            .shadow(color: NomiTheme.ink.opacity(0.05), radius: 16, y: 6)
            .animation(.easeInOut(duration: 0.22), value: model.materials)
            .transition(.opacity)
        }

        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip for now") {
                guard !model.hasBusyMaterials else { return }
                finish(delay: .milliseconds(180))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(NomiTheme.blue)
            .buttonStyle(.plain)
            .disabled(model.hasBusyMaterials || isFinishing)

            Spacer()

            Button {
                guard model.canContinue else { return }
                finish(delay: .milliseconds(420))
            } label: {
                Group {
                    if isFinishing {
                        Image(systemName: "checkmark")
                    } else {
                        Image(systemName: "arrow.right")
                    }
                }
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(continueColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.canContinue || isFinishing)
            .accessibilityLabel("Continue to your course")
            .animation(.easeInOut(duration: 0.2), value: model.canContinue)
        }
        .frame(height: 52)
    }

    private var mascotAsset: String {
        if model.hasBusyMaterials { return "NomiThinking" }
        if model.materials.contains(where: { $0.phase == .ready }) { return "NomiConfirm" }
        if model.materials.contains(where: {
            if case .failed = $0.phase { return true }
            return false
        }) { return "NomiNudge" }
        return "NomiIdle"
    }

    private var continueColor: Color {
        model.canContinue ? NomiTheme.blue : NomiTheme.blueMuted
    }

    private func finish(delay: Duration) {
        guard !isFinishing else { return }
        isFinishing = true
        Task { @MainActor in
            if !reduceMotion { try? await Task.sleep(for: delay) }
            onCompleted()
        }
    }
}

private struct MaterialRow: View {
    let item: CourseMaterialItem
    let isNotebookSource: Bool
    let isChangingNotebook: Bool
    let onToggleNotebook: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.82))
                .frame(width: 36, height: 36)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let byteCount = item.byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
                    }
                    Text(statusText)
                }
                .font(.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if item.phase == .ready {
                Button(action: onToggleNotebook) {
                    HStack(spacing: 6) {
                        if isChangingNotebook {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(NomiTheme.blue)
                        } else {
                            Image(systemName: isNotebookSource ? "checkmark.circle.fill" : "circle")
                        }

                        Text(isNotebookSource ? "In notebook" : "Use in notebook")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isNotebookSource ? NomiTheme.blue : NomiTheme.secondaryInk)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        isNotebookSource ? NomiTheme.blue.opacity(0.09) : Color.clear,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                isNotebookSource ? Color.clear : NomiTheme.hairline,
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(isChangingNotebook)
                .accessibilityLabel(
                    isNotebookSource
                        ? "Remove \(item.title) from the notebook canvas"
                        : "Use \(item.title) as the notebook canvas"
                )
            } else if item.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(NomiTheme.blue)
            }

            if !item.phase.isBusy {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NomiTheme.secondaryInk)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.title)")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
    }

    private var statusText: String {
        switch item.phase {
        case .uploading: "Adding context…"
        case .ready: "Ready"
        case .deleting: "Removing…"
        case let .failed(message): message
        }
    }

    private var statusColor: Color {
        switch item.phase {
        case .ready: .green
        case .failed: .orange
        default: NomiTheme.secondaryInk
        }
    }
}
