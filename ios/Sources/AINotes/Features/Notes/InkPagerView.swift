import PencilKit
import SwiftUI
import UIKit

/// GoodNotes-style notebook surface.
///
/// One page is shown at a time; swipe sideways to move between pages. Each page
/// is a `PKCanvasView` that *owns its own zoom*, so ink is re-tessellated as
/// vectors at every zoom level and stays crisp (unlike a PencilKit overlay on a
/// PDFView, which the system transform-scales into a blurry raster). The page
/// background (paper template or rendered PDF page) is inserted *inside* the
/// canvas's zooming content view so it scales together with the ink.
///
/// When `canAddPage` is true, swiping past the last page reveals an "add page"
/// affordance; landing on it appends a new page via `onAddPage`.
struct InkPagerView: UIViewControllerRepresentable {
    /// Number of real pages.
    let pageCount: Int
    /// Changes whenever the pages need to be rebuilt (template/color/mode/count).
    let signature: String
    /// Persistence key for this note's per-page ink.
    let storeKey: String
    /// Page size in points (drawing coordinate space) for a given page index.
    let canonicalSize: (Int) -> CGSize
    /// High-resolution background bitmap for a given page index.
    let background: (Int) -> UIImage?
    var canAddPage: Bool = false
    var onAddPage: (() -> Void)?
    /// Live tutor that watches the active page (optional).
    var shadowing: ShadowingEngine?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 24]
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .secondarySystemBackground
        context.coordinator.pager = pager
        context.coordinator.rebuild(initialIndex: 0, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncIfNeeded()
    }

    static func dismantleUIViewController(_ pager: UIPageViewController, coordinator: Coordinator) {
        coordinator.flush()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: InkPagerView
        weak var pager: UIPageViewController?

        private var currentSignature = ""
        private var currentStoreKey = ""
        private var currentIndex = 0
        private var pendingAdd = false

        private var drawings: [Int: Data]
        private var saveTask: Task<Void, Never>?
        private let toolPicker = PKToolPicker()
        private weak var activeCanvas: PKCanvasView?

        init(_ parent: InkPagerView) {
            self.parent = parent
            self.currentSignature = parent.signature
            self.currentStoreKey = parent.storeKey
            self.drawings = PDFNoteStore.loadDrawings(key: parent.storeKey)
        }

        /// Index of the trailing "add page" placeholder, or `nil` if disabled.
        private var addSlot: Int? { parent.canAddPage ? parent.pageCount : nil }

        // MARK: Build / refresh

        func rebuild(initialIndex: Int, animated: Bool) {
            currentSignature = parent.signature
            let clamped = min(max(0, initialIndex), max(0, parent.pageCount - 1))
            currentIndex = clamped
            guard let vc = makePage(clamped) else { return }
            pager?.setViewControllers([vc], direction: .forward, animated: animated)
        }

        func syncIfNeeded() {
            if currentStoreKey != parent.storeKey {
                flush()
                currentStoreKey = parent.storeKey
                drawings = PDFNoteStore.loadDrawings(key: parent.storeKey)
                currentSignature = ""   // force a rebuild for the new note
            }
            guard currentSignature != parent.signature else { return }
            // If we just landed on the "add page" slot, show the freshly added page.
            let target = pendingAdd ? parent.pageCount - 1 : currentIndex
            pendingAdd = false
            rebuild(initialIndex: target, animated: false)
        }

        private func makePage(_ index: Int) -> UIViewController? {
            if let add = addSlot, index == add {
                return AddPagePlaceholderController()
            }
            guard index >= 0, index < parent.pageCount else { return nil }
            return InkPageController(
                pageIndex: index,
                canonicalSize: parent.canonicalSize(index),
                background: parent.background(index),
                coordinator: self
            )
        }

        private func indexOf(_ vc: UIViewController) -> Int {
            if let page = vc as? InkPageController { return page.pageIndex }
            if vc is AddPagePlaceholderController { return addSlot ?? currentIndex }
            return currentIndex
        }

        // MARK: UIPageViewControllerDataSource

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            let idx = indexOf(vc)
            return idx > 0 ? makePage(idx - 1) : nil
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            let idx = indexOf(vc)
            let last = parent.pageCount - 1
            if idx < last { return makePage(idx + 1) }
            if idx == last, let add = addSlot { return makePage(add) }
            return nil
        }

        // MARK: UIPageViewControllerDelegate

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed, let current = pvc.viewControllers?.first else { return }
            if current is AddPagePlaceholderController {
                // Landed on the trailing add-page affordance: append a real page.
                pendingAdd = true
                parent.onAddPage?()
            } else {
                currentIndex = indexOf(current)
                if let page = current as? InkPageController { activate(page: page) }
            }
        }

        // MARK: Active canvas + tool picker

        func activate(page: InkPageController) {
            let canvas = page.canvasView
            activeCanvas = canvas
            toolPicker.setVisible(true, forFirstResponder: canvas)
            toolPicker.addObserver(canvas)
            canvas.becomeFirstResponder()
            // Point the tutor at whatever page is currently on screen.
            parent.shadowing?.setActivePage(page.pageIndex)
            parent.shadowing?.snapshotProvider = { [weak page] maxWidth in
                page?.snapshot(maxWidth: maxWidth)
            }
        }

        func drawingChanged(strokeCount: Int) {
            parent.shadowing?.noteDrawingChanged(strokeCount: strokeCount)
        }

        // MARK: Drawing persistence

        func drawing(for index: Int) -> PKDrawing? {
            guard let data = drawings[index] else { return nil }
            return try? PKDrawing(data: data)
        }

        func updateDrawing(_ drawing: PKDrawing, for index: Int) {
            drawings[index] = drawing.dataRepresentation()
            scheduleSave()
        }

        private func scheduleSave() {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !Task.isCancelled else { return }
                self.flush()
            }
        }

        func flush() {
            PDFNoteStore.saveDrawings(drawings, key: currentStoreKey)
        }
    }
}

// MARK: - Single zoomable page

/// A single notebook page: a `PKCanvasView` that owns its zoom, with a
/// high-resolution background image placed inside its zooming content view.
final class InkPageController: UIViewController, PKCanvasViewDelegate, UIScrollViewDelegate {
    let pageIndex: Int
    private let canonicalSize: CGSize
    private let background: UIImage?
    private weak var coordinator: InkPagerView.Coordinator?

    let canvasView = PKCanvasView()
    private let backgroundView = UIImageView()
    private var didConfigureZoom = false
    private var didAttachBackground = false
    private var lastStrokeCount = 0
    private var isMutatingDrawing = false   // guard against re-entrant drawing edits

    init(pageIndex: Int,
         canonicalSize: CGSize,
         background: UIImage?,
         coordinator: InkPagerView.Coordinator?) {
        self.pageIndex = pageIndex
        self.canonicalSize = canonicalSize
        self.background = background
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        canvasView.frame = view.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.drawingPolicy = .pencilOnly     // pencil draws; finger scrolls/zooms
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.bounces = false                  // don't rubber-band at fit, so swipes can page
        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.contentSize = canonicalSize
        canvasView.delegate = self
        view.addSubview(canvasView)

        backgroundView.frame = CGRect(origin: .zero, size: canonicalSize)
        backgroundView.image = background
        backgroundView.contentMode = .scaleToFill
        backgroundView.layer.borderColor = UIColor.separator.cgColor
        backgroundView.layer.borderWidth = 0.5

        if let drawing = coordinator?.drawing(for: pageIndex) {
            canvasView.drawing = drawing
        }
        lastStrokeCount = canvasView.drawing.strokes.count
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachBackgroundIfNeeded()
        configureZoomIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        coordinator?.activate(page: self)
    }

    /// Renders this page (background + ink) to a bitmap no wider than `maxWidth`
    /// points, for the shadowing tutor to analyze.
    func snapshot(maxWidth: CGFloat) -> UIImage? {
        guard canonicalSize.width > 0, canonicalSize.height > 0 else { return nil }
        let scale = max(0.1, maxWidth / canonicalSize.width)
        let size = canonicalSize
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            if let bg = background {
                bg.draw(in: CGRect(origin: .zero, size: size))
            } else {
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            let ink = canvasView.drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// PencilKit's first subview is its zooming content view. Placing the
    /// background there makes it zoom together with the (vector) ink.
    private func attachBackgroundIfNeeded() {
        guard !didAttachBackground, let content = canvasView.subviews.first else { return }
        content.insertSubview(backgroundView, at: 0)
        didAttachBackground = true
    }

    private func configureZoomIfNeeded() {
        guard !didConfigureZoom,
              canvasView.bounds.width > 0, canvasView.bounds.height > 0,
              canonicalSize.width > 0, canonicalSize.height > 0 else { return }
        // Fit the whole page in view at rest; allow zooming in up to 5x beyond fit.
        let fit = min(canvasView.bounds.width / canonicalSize.width,
                      canvasView.bounds.height / canonicalSize.height)
        canvasView.minimumZoomScale = fit
        canvasView.maximumZoomScale = fit * 5
        canvasView.zoomScale = fit
        centerContent()
        didConfigureZoom = true
    }

    /// Keep the page centered when it's smaller than the viewport.
    private func centerContent() {
        let viewport = canvasView.bounds.size
        let content = CGSize(width: canonicalSize.width * canvasView.zoomScale,
                             height: canonicalSize.height * canvasView.zoomScale)
        let x = max(0, (viewport.width - content.width) / 2)
        let y = max(0, (viewport.height - content.height) / 2)
        canvasView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if isMutatingDrawing { return }
        let strokes = canvasView.drawing.strokes

        // A single newly-committed stroke may be a "scribble to erase" gesture.
        if strokes.count == lastStrokeCount + 1,
           let erased = ScribbleEraser.apply(to: canvasView.drawing, newStrokeIndex: strokes.count - 1) {
            isMutatingDrawing = true
            canvasView.drawing = erased
            isMutatingDrawing = false
            lastStrokeCount = erased.strokes.count
            persistAndNotify(erased)
            return
        }

        lastStrokeCount = strokes.count
        persistAndNotify(canvasView.drawing)
    }

    private func persistAndNotify(_ drawing: PKDrawing) {
        coordinator?.updateDrawing(drawing, for: pageIndex)
        coordinator?.drawingChanged(strokeCount: drawing.strokes.count)
    }

    // MARK: UIScrollViewDelegate (PKCanvasViewDelegate refines it)

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }
}

// MARK: - Add-page affordance

/// The page you reach by swiping past the last real page: a dashed placeholder
/// that reads as "release to add a page".
final class AddPagePlaceholderController: UIViewController {
    private let card = UIView()
    private let dashed = CAShapeLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        card.translatesAutoresizingMaskIntoConstraints = false
        dashed.strokeColor = UIColor.tertiaryLabel.cgColor
        dashed.fillColor = UIColor.systemBackground.withAlphaComponent(0.4).cgColor
        dashed.lineDashPattern = [10, 8]
        dashed.lineWidth = 2
        card.layer.addSublayer(dashed)

        let plus = UIImageView(image: UIImage(systemName: "plus.circle"))
        plus.tintColor = .tertiaryLabel
        plus.contentMode = .scaleAspectFit
        plus.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "New page"
        label.textColor = .tertiaryLabel
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [plus, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(card)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),
            card.heightAnchor.constraint(equalTo: card.widthAnchor, multiplier: 1.3),
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 64),
            plus.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dashed.frame = card.bounds
        dashed.path = UIBezierPath(roundedRect: card.bounds, cornerRadius: 16).cgPath
    }
}
