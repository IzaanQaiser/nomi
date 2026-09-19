import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum NoteMode { case paper, pdf }

/// Caches rendered page backgrounds so swiping between pages doesn't re-render
/// (expensive) bitmaps each time. Keyed by "<signature>-<pageIndex>".
final class BackgroundCache {
    private let cache = NSCache<NSString, UIImage>()
    func image(_ key: String, _ make: () -> UIImage?) -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let img = make() else { return nil }
        cache.setObject(img, forKey: key as NSString)
        return img
    }
}

/// The notebook canvas. One page at a time; swipe sideways between pages, and
/// swipe past the last page onto the "New page" affordance to append one.
///
/// Ink stays crisp at any zoom because each page's `PKCanvasView` owns its own
/// zoom (see `InkPagerView`). Paper templates and imported PDF pages are drawn
/// as high-resolution backgrounds behind the ink.
struct NotesView: View {
    @State private var mode: NoteMode
    @State private var paperStyle: PaperStyle
    @State private var paperColor: PaperColor
    @State private var paperPages: Int
    @State private var pdfURL: URL?
    @State private var pdfDocument: PDFDocument?
    @State private var showPDFImporter = false
    @State private var importError: String?
    @State private var bgCache = BackgroundCache()
    /// Custom drawing tools (replaces Apple's PKToolPicker) + undo/redo state.
    @StateObject private var tools = NoteToolController()
    @ObservedObject var shadowing: ShadowingEngine

    private let project: Project
    /// Fixed paper page size in points (~US Letter aspect). Ink is stored in
    /// these coordinates, so it's stable regardless of screen size.
    private let paperSize = CGSize(width: 1024, height: 1325)

    private var styleKey: String { "paperStyle-\(project.id)" }
    private var colorKey: String { "paperColor-\(project.id)" }
    private var pagesKey: String { "paperPages-\(project.id)" }
    private var storeKey: String { mode == .pdf ? "\(project.id)-pdf" : "\(project.id)-paper" }

    init(project: Project, shadowing: ShadowingEngine) {
        self.project = project
        _shadowing = ObservedObject(wrappedValue: shadowing)
        let defaults = UserDefaults.standard
        _paperStyle = State(initialValue: PaperStyle(rawValue: defaults.string(forKey: "paperStyle-\(project.id)") ?? "") ?? .ruled)
        _paperColor = State(initialValue: PaperColor(rawValue: defaults.string(forKey: "paperColor-\(project.id)") ?? "") ?? .white)
        _paperPages = State(initialValue: max(1, defaults.integer(forKey: "paperPages-\(project.id)")))
        let storedPDFURL = PDFNoteStore.hasPDF(projectId: project.id)
            ? PDFNoteStore.pdfURL(projectId: project.id)
            : nil
        let storedPDF = storedPDFURL.flatMap(PDFDocument.init(url:))
        _mode = State(initialValue: storedPDF == nil ? .paper : .pdf)
        _pdfURL = State(initialValue: storedPDFURL)
        _pdfDocument = State(initialValue: storedPDF)
    }

    // MARK: Page model

    private var pageCount: Int {
        switch mode {
        case .paper: return max(1, paperPages)
        case .pdf: return pdfDocument?.pageCount ?? 0
        }
    }

    private var signature: String {
        switch mode {
        case .paper: return "paper-\(paperStyle.rawValue)-\(paperColor.rawValue)-\(paperPages)"
        case .pdf: return "pdf-\(pdfURL?.lastPathComponent ?? "none")-\(pageCount)"
        }
    }

    private func canonicalSize(_ index: Int) -> CGSize {
        switch mode {
        case .paper:
            return paperSize
        case .pdf:
            guard let page = pdfDocument?.page(at: index) else { return paperSize }
            let b = page.bounds(for: .mediaBox).size
            return b.width > 0 && b.height > 0 ? b : paperSize
        }
    }

    private func background(_ index: Int) -> UIImage? {
        switch mode {
        case .paper:
            return bgCache.image("\(signature)-\(index)") {
                PaperPDF.image(
                    style: paperStyle,
                    fill: paperColor.fill,
                    line: paperColor.line,
                    size: paperSize,
                    scale: 3
                )
            }
        case .pdf:
            guard let page = pdfDocument?.page(at: index) else { return nil }
            return bgCache.image("\(signature)-\(index)") {
                Self.renderPDFPage(page, scale: 2)
            }
        }
    }

    // MARK: Body

    var body: some View {
        InkPagerView(
            pageCount: pageCount,
            signature: signature,
            storeKey: storeKey,
            canonicalSize: canonicalSize,
            background: background,
            canAddPage: mode == .paper,
            onAddPage: addPage,
            shadowing: shadowing,
            tools: tools
        )
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            PenIslandView(tools: tools)
        }
        .overlay(alignment: .topTrailing) {
            MascotView(engine: shadowing)
                .padding(.top, 10)
                .padding(.trailing, 14)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    tools.requestUndo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!tools.canUndo)
                Button {
                    tools.requestRedo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!tools.canRedo)
                pageSettingsMenu
            }
        }
        .onAppear { loadPDFIfNeeded() }
        .onChange(of: paperStyle) { _, style in
            UserDefaults.standard.set(style.rawValue, forKey: styleKey)
        }
        .onChange(of: paperColor) { _, color in
            UserDefaults.standard.set(color.rawValue, forKey: colorKey)
        }
        .onChange(of: mode) { _, _ in loadPDFIfNeeded() }
        .fileImporter(
            isPresented: $showPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let picked = urls.first {
                importPDF(picked)
            }
        }
        .alert("PDF import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    // MARK: Actions

    private func loadPDFIfNeeded() {
        guard mode == .pdf else { return }
        if pdfDocument == nil, let url = pdfURL {
            pdfDocument = PDFDocument(url: url)
        }
        if pdfDocument == nil { mode = .paper }   // fall back if the PDF is missing
    }

    /// Append a page of the current template (paper only).
    private func addPage() {
        paperPages += 1
        UserDefaults.standard.set(paperPages, forKey: pagesKey)
    }

    private func importPDF(_ picked: URL) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        do {
            let stored = try PDFNoteStore.importPDF(from: picked, projectId: project.id)
            pdfURL = stored
            pdfDocument = PDFDocument(url: stored)
            mode = .pdf
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Renders a PDF page to a high-resolution bitmap used as a page background.
    private static func renderPDFPage(_ page: PDFPage, scale: CGFloat) -> UIImage {
        let size = page.bounds(for: .mediaBox).size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
        }
    }

    // MARK: Page settings (top-corner menu)

    private var pageSettingsMenu: some View {
        Menu {
            Picker("Template", selection: $paperStyle) {
                ForEach(PaperStyle.allCases) { style in
                    Label(style.label, systemImage: style.systemImage).tag(style)
                }
            }

            Picker("Page color", selection: $paperColor) {
                ForEach(PaperColor.allCases) { color in
                    Text(color.label).tag(color)
                }
            }

            if mode == .paper {
                Section("Pages (\(paperPages))") {
                    Button {
                        addPage()
                    } label: { Label("Add page", systemImage: "plus.rectangle.on.rectangle") }
                }
            }

            Section("Background") {
                if mode == .pdf {
                    Button {
                        mode = .paper
                    } label: { Label("Use paper", systemImage: "doc.plaintext") }
                } else if pdfURL != nil {
                    Button {
                        mode = .pdf
                    } label: { Label("Use imported PDF", systemImage: "doc.richtext") }
                }
                Button {
                    showPDFImporter = true
                } label: {
                    Label(pdfURL == nil ? "Import PDF…" : "Replace PDF…", systemImage: "doc.badge.plus")
                }
            }
        } label: {
            Label("Page settings", systemImage: "gearshape")
        }
        .menuOrder(.fixed)
    }
}
