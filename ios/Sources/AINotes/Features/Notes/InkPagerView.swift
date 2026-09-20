import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    /// Drawing tools (pen/eraser/lasso/color/width) + undo/redo, driven by the
    /// custom floating island instead of Apple's `PKToolPicker`.
    @ObservedObject var tools: NoteToolController

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
        context.coordinator.applyToolState()
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
        private var pageImages: [Int: [PageImageStore.Item]]
        private var saveTask: Task<Void, Never>?
        private weak var activeCanvas: NotesCanvasView?
        private weak var activePage: InkPageController?
        private var lastUndoNonce = 0
        private var lastRedoNonce = 0

        init(_ parent: InkPagerView) {
            self.parent = parent
            self.currentSignature = parent.signature
            self.currentStoreKey = parent.storeKey
            self.drawings = PDFNoteStore.loadDrawings(key: parent.storeKey)
            self.pageImages = PageImageStore.load(key: parent.storeKey)
            self.lastUndoNonce = parent.tools.undoNonce
            self.lastRedoNonce = parent.tools.redoNonce
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
                pageImages = PageImageStore.load(key: parent.storeKey)
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

        // MARK: Active canvas + custom tools

        func activate(page: InkPageController) {
            let canvas = page.canvasView
            activeCanvas = canvas
            activePage = page
            // No PKToolPicker — the custom island drives the tool. First responder
            // is still needed so the canvas owns the undo manager.
            canvas.becomeFirstResponder()
            canvas.tool = parent.tools.pkTool
            refreshUndoState()
            parent.shadowing?.setActivePage(page.pageIndex)
            // Read the *current* active page (a captured page could go stale when
            // the page controller is recycled, silently returning no scan).
            parent.shadowing?.snapshotProvider = { [weak self] maxWidth in
                self?.activePage?.snapshot(maxWidth: maxWidth)
            }
        }

        /// Push the island's tool selection onto the live canvas and service any
        /// pending undo/redo requests. Called on every SwiftUI update.
        func applyToolState() {
            let canvas = activeCanvas ?? activePage?.canvasView
            canvas?.tool = parent.tools.pkTool

            if parent.tools.undoNonce != lastUndoNonce {
                lastUndoNonce = parent.tools.undoNonce
                canvas?.undoManager?.undo()
                refreshUndoState()
            }
            if parent.tools.redoNonce != lastRedoNonce {
                lastRedoNonce = parent.tools.redoNonce
                canvas?.undoManager?.redo()
                refreshUndoState()
            }
        }

        /// Mirror the canvas undo manager's state onto the island buttons.
        func refreshUndoState() {
            let mgr = (activeCanvas ?? activePage?.canvasView)?.undoManager
            let canUndo = mgr?.canUndo ?? false
            let canRedo = mgr?.canRedo ?? false
            // Avoid "publishing during view update" by deferring the write.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.tools.canUndo != canUndo { self.parent.tools.canUndo = canUndo }
                if self.parent.tools.canRedo != canRedo { self.parent.tools.canRedo = canRedo }
            }
        }

        func drawingChanged(strokeCount: Int) {
            parent.shadowing?.noteDrawingChanged(strokeCount: strokeCount)
            refreshUndoState()
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

        func images(for index: Int) -> [PageImageStore.Item] {
            pageImages[index] ?? []
        }

        func updateImages(_ items: [PageImageStore.Item], for index: Int) {
            pageImages[index] = items
            scheduleSave()
        }

        var storeKey: String { currentStoreKey }

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
            PageImageStore.save(pageImages, key: currentStoreKey)
        }
    }
}

// MARK: - Canvas subclass (clipboard paste for images + ink)

/// Extends PencilKit so Paste can insert clipboard images, while still
/// forwarding ink cut/copy/paste to the system lasso selection handlers.
final class NotesCanvasView: PKCanvasView {
    var onPasteImage: ((UIImage) -> Void)?
    var onPasteDrawing: ((PKDrawing) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasImages || Self.drawingFromPasteboard() != nil
        }
        // Hide PencilKit's blank-canvas edit items (Select / Select All / Insert
        // Space) so a long-press over a clipboard image offers just "Paste".
        // The pen island owns the lasso; copy/cut/delete still work on an active
        // lasso selection (they fall through to super).
        if action == #selector(select(_:)) || action == #selector(selectAll(_:)) {
            return false
        }
        let name = NSStringFromSelector(action).lowercased()
        if name.contains("insertspace") || name.contains("insert_space") {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let image = UIPasteboard.general.image {
            onPasteImage?(image)
            return
        }
        if let drawing = Self.drawingFromPasteboard() {
            onPasteDrawing?(drawing)
            return
        }
        super.paste(sender)
    }

    static func drawingFromPasteboard() -> PKDrawing? {
        let board = UIPasteboard.general
        if let data = board.data(forPasteboardType: UTType.pkDrawing.identifier),
           let drawing = try? PKDrawing(data: data) {
            return drawing
        }
        // Some system copies use a private PencilKit UTI; try common fallbacks.
        for type in board.types {
            if type.lowercased().contains("pencilkit") || type.lowercased().contains("drawing"),
               let data = board.data(forPasteboardType: type),
               let drawing = try? PKDrawing(data: data) {
                return drawing
            }
        }
        return nil
    }
}

private extension UTType {
    static var pkDrawing: UTType {
        UTType(exportedAs: "com.apple.pencilkit.drawing")
    }
}

// MARK: - Single zoomable page

/// A single notebook page: a `PKCanvasView` that owns its zoom, with a
/// high-resolution background image placed inside its zooming content view.
final class InkPageController: UIViewController, PKCanvasViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    let pageIndex: Int
    private let canonicalSize: CGSize
    private let background: UIImage?
    private weak var coordinator: InkPagerView.Coordinator?

    let canvasView = NotesCanvasView()
    private let backgroundView = UIImageView()
    /// Holds pasted photos *below* the ink, so pencil strokes draw on top of them.
    private let imageLayer = UIView()
    /// Draws selection chrome (border + delete badge) *above* the ink; non-interactive.
    private let selectionLayer = SelectionOverlayView()
    private var imageViews: [String: UIImageView] = [:]
    private var selectedID: String?
    private var didConfigureZoom = false
    private var didAttachBackground = false
    private var lastStrokeCount = 0
    private var isMutatingDrawing = false   // guard against re-entrant drawing edits

    /// Smallest a photo can be shrunk to (canonical points).
    private let minImageSide: CGFloat = 60
    /// Tap target (canonical points) for the corner delete badge.
    private let deleteBadgeSide: CGFloat = 38
    /// How near a corner a finger must land to grab a resize handle.
    private let cornerHitRadius: CGFloat = 64

    enum ResizeCorner { case topLeft, topRight, bottomLeft, bottomRight }

    // Live gesture state while dragging / resizing a photo with a finger.
    private var activeImageID: String?
    private var gestureStartFrame: CGRect = .zero
    private var activeCorner: ResizeCorner?

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
        // Paper is always white, so pin the canvas to light mode. Otherwise
        // PencilKit's dark-mode adaptation flips black ink to white (invisible
        // on white paper) even though the tool swatch still shows black.
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.drawingPolicy = .pencilOnly     // pencil draws; finger scrolls/zooms / drags images
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.bounces = false                  // don't rubber-band at fit, so swipes can page
        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.contentSize = canonicalSize
        canvasView.delegate = self
        canvasView.onPasteImage = { [weak self] image in
            self?.insertPastedImage(image, at: self?.pasteLocation)
        }
        canvasView.onPasteDrawing = { [weak self] drawing in
            self?.insertPastedDrawing(drawing, at: self?.pasteLocation)
        }
        view.addSubview(canvasView)

        backgroundView.frame = CGRect(origin: .zero, size: canonicalSize)
        backgroundView.image = background
        backgroundView.contentMode = .scaleToFill
        backgroundView.layer.borderColor = UIColor.separator.cgColor
        backgroundView.layer.borderWidth = 0.5

        imageLayer.frame = CGRect(origin: .zero, size: canonicalSize)
        imageLayer.isUserInteractionEnabled = false   // finger gestures live on the canvas
        imageLayer.clipsToBounds = false

        selectionLayer.frame = CGRect(origin: .zero, size: canonicalSize)
        selectionLayer.isUserInteractionEnabled = false
        selectionLayer.backgroundColor = .clear

        if let drawing = coordinator?.drawing(for: pageIndex) {
            canvasView.drawing = drawing
        }
        lastStrokeCount = canvasView.drawing.strokes.count

        installImageGestures()
    }

    /// Finger-only recognizers that select / drag / resize / delete pasted photos.
    /// They hit-test photo frames manually; because the canvas is `.pencilOnly`,
    /// the pencil never triggers them and always draws instead.
    private func installImageGestures() {
        let finger = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleImagePan(_:)))
        pan.allowedTouchTypes = finger
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        canvasView.addGestureRecognizer(pan)
        // Let the photo drag win over page scrolling when it starts on a photo.
        canvasView.panGestureRecognizer.require(toFail: pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleImagePinch(_:)))
        pinch.allowedTouchTypes = finger
        pinch.delegate = self
        canvasView.addGestureRecognizer(pinch)
        canvasView.pinchGestureRecognizer?.require(toFail: pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:)))
        tap.allowedTouchTypes = finger
        tap.delegate = self
        canvasView.addGestureRecognizer(tap)

        // Press-and-hold anywhere to paste a clipboard photo/ink at that spot,
        // native-style (an edit menu with a Paste action).
        canvasView.addInteraction(editMenuInteraction)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.allowedTouchTypes = finger
        longPress.delegate = self
        canvasView.addGestureRecognizer(longPress)
    }

    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)
    /// Content-space point where the next paste should land (nil = page center).
    private var pasteLocation: CGPoint?

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let content = contentView else { return }
        pasteLocation = g.location(in: content)
        guard UIPasteboard.general.hasImages || NotesCanvasView.drawingFromPasteboard() != nil else { return }
        // PencilKit shows its own "Select All / Insert Space" menu on long-press;
        // drop it so only our Paste menu appears.
        removeSystemEditMenus(in: canvasView)
        let point = g.location(in: canvasView)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
            self.editMenuInteraction.presentEditMenu(with: config)
        }
    }

    /// Remove PencilKit's built-in edit-menu interactions (ours is preserved) so
    /// the blank-canvas menu doesn't compete with our Paste menu.
    private func removeSystemEditMenus(in view: UIView) {
        for interaction in view.interactions
        where interaction is UIEditMenuInteraction && !(interaction === editMenuInteraction) {
            view.removeInteraction(interaction)
        }
        for sub in view.subviews { removeSystemEditMenus(in: sub) }
    }

    private func pasteAtPasteLocation() {
        if let image = UIPasteboard.general.image {
            insertPastedImage(image, at: pasteLocation)
        } else if let drawing = NotesCanvasView.drawingFromPasteboard() {
            insertPastedDrawing(drawing, at: pasteLocation)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachBackgroundIfNeeded()
        configureZoomIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        coordinator?.activate(page: self)
        reloadOverlays()
    }

    override var canBecomeFirstResponder: Bool { false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Edit actions are handled by the canvas / overlay callbacks.
        return false
    }

    override func paste(_ sender: Any?) {
        pasteFromClipboard()
    }

    override func copy(_ sender: Any?) {
        // no-op — canvas is the edit target
    }

    override func delete(_ sender: Any?) {
        // no-op
    }

    func pasteFromClipboard() {
        if let image = UIPasteboard.general.image {
            insertPastedImage(image)
            return
        }
        if let drawing = NotesCanvasView.drawingFromPasteboard() {
            insertPastedDrawing(drawing)
            return
        }
        // Fall back to PencilKit's paste (lasso-copied strokes).
        canvasView.paste(nil)
    }

    /// Renders this page (background + pasted images + ink) to a bitmap no wider
    /// than `maxWidth` points, for the shadowing tutor to analyze.
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
            for item in currentItems() {
                if let key = coordinator?.storeKey,
                   let img = PageImageStore.loadImage(key: key, fileName: item.fileName) {
                    img.draw(in: item.frame)
                }
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
        // Photos sit just above the paper but below the ink, so the pencil writes
        // over them. Selection chrome sits on top of everything.
        content.insertSubview(imageLayer, aboveSubview: backgroundView)
        content.addSubview(selectionLayer)
        didAttachBackground = true
        reloadOverlays()
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

    // MARK: Pasted images

    private func currentItems() -> [PageImageStore.Item] {
        coordinator?.images(for: pageIndex) ?? []
    }

    private func persistItems(_ items: [PageImageStore.Item]) {
        coordinator?.updateImages(items, for: pageIndex)
    }

    /// Content coordinate space (canonical points) that photo frames live in.
    private var contentView: UIView? { canvasView.subviews.first }

    private func reloadOverlays() {
        guard didAttachBackground else { return }
        let items = currentItems()
        let keep = Set(items.map(\.id))
        for (id, view) in imageViews where !keep.contains(id) {
            view.removeFromSuperview()
            imageViews.removeValue(forKey: id)
        }
        guard let key = coordinator?.storeKey else { return }
        // Rebuild in array order so later paste = higher photo (matches hit-testing).
        for item in items {
            let view: UIImageView
            if let existing = imageViews[item.id] {
                view = existing
            } else {
                view = UIImageView(image: PageImageStore.loadImage(key: key, fileName: item.fileName))
                view.contentMode = .scaleAspectFill
                view.clipsToBounds = true
                view.isUserInteractionEnabled = false
                view.layer.cornerRadius = 4
                imageViews[item.id] = view
            }
            imageLayer.addSubview(view)   // re-add to enforce z-order
            view.frame = item.frame
        }
        if let selectedID, !keep.contains(selectedID) { self.selectedID = nil }
        updateSelectionChrome()
    }

    private func updateSelectionChrome() {
        if let id = selectedID, let item = currentItems().first(where: { $0.id == id }) {
            selectionLayer.selection = item.frame
            selectionLayer.deleteBadge = deleteBadgeRect(for: item.frame)
        } else {
            selectionLayer.selection = nil
            selectionLayer.deleteBadge = nil
        }
    }

    /// Circular delete target hugging the photo's top-left corner (canonical points).
    private func deleteBadgeRect(for frame: CGRect) -> CGRect {
        let d = deleteBadgeSide
        return CGRect(x: frame.minX - d / 2, y: frame.minY - d / 2, width: d, height: d)
    }

    /// Insert a photo centered on `center` (content coords), or the page center
    /// when `center` is nil. Clamped to stay on the page.
    private func insertPastedImage(_ image: UIImage, at center: CGPoint? = nil) {
        guard let key = coordinator?.storeKey else { return }
        let id = UUID().uuidString
        let fileName = "\(id).png"
        let maxSide: CGFloat = min(canonicalSize.width, canonicalSize.height) * 0.45
        let aspect = image.size.width / max(image.size.height, 1)
        var size = CGSize(width: maxSide, height: maxSide / max(aspect, 0.01))
        if size.height > maxSide {
            size = CGSize(width: maxSide * aspect, height: maxSide)
        }
        let c = center ?? CGPoint(x: canonicalSize.width / 2, y: canonicalSize.height / 2)
        var origin = CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        origin.x = max(0, min(origin.x, canonicalSize.width - size.width))
        origin.y = max(0, min(origin.y, canonicalSize.height - size.height))
        PageImageStore.saveImage(image, key: key, fileName: fileName)
        var items = currentItems()
        items.append(PageImageStore.Item(
            id: id, x: origin.x, y: origin.y,
            width: size.width, height: size.height, fileName: fileName
        ))
        persistItems(items)
        selectedID = id
        reloadOverlays()
        // Keep PencilKit as first responder so writing / undo keep working.
        canvasView.becomeFirstResponder()
    }

    private func insertPastedDrawing(_ drawing: PKDrawing, at point: CGPoint? = nil) {
        // Center the pasted ink on `point` (or offset it slightly otherwise).
        let transform: CGAffineTransform
        if let point {
            let b = drawing.bounds
            transform = CGAffineTransform(translationX: point.x - b.midX, y: point.y - b.midY)
        } else {
            transform = CGAffineTransform(translationX: 36, y: 36)
        }
        let shiftedStrokes = drawing.strokes.map { stroke in
            PKStroke(
                ink: stroke.ink,
                path: stroke.path,
                transform: stroke.transform.concatenating(transform),
                mask: stroke.mask
            )
        }
        isMutatingDrawing = true
        canvasView.drawing = PKDrawing(strokes: canvasView.drawing.strokes + shiftedStrokes)
        isMutatingDrawing = false
        lastStrokeCount = canvasView.drawing.strokes.count
        persistAndNotify(canvasView.drawing)
    }

    // MARK: UIEditMenuInteractionDelegate (press-and-hold paste)

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard UIPasteboard.general.hasImages || NotesCanvasView.drawingFromPasteboard() != nil else {
            return nil
        }
        let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.pasteAtPasteLocation()
        }
        return UIMenu(children: [paste])
    }

    private func selectOverlay(id: String?) {
        selectedID = id
        updateSelectionChrome()
    }

    private func deselectOverlays() {
        guard selectedID != nil else { return }
        selectedID = nil
        updateSelectionChrome()
    }

    /// Topmost photo (last in array wins) whose frame contains `point`, or nil.
    private func topImageID(at point: CGPoint) -> String? {
        for item in currentItems().reversed() where item.frame.contains(point) {
            return item.id
        }
        return nil
    }

    private func frame(of id: String) -> CGRect? {
        currentItems().first(where: { $0.id == id })?.frame
    }

    /// Move `id`'s frame, clamped to stay on the page. Updates the live view and
    /// selection chrome; persists only when `persist` is true (drag end).
    private func setFrame(_ frame: CGRect, for id: String, persist: Bool) {
        var items = currentItems()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var clamped = frame
        clamped.size.width = min(clamped.size.width, canonicalSize.width)
        clamped.size.height = min(clamped.size.height, canonicalSize.height)
        clamped.origin.x = max(0, min(clamped.origin.x, canonicalSize.width - clamped.width))
        clamped.origin.y = max(0, min(clamped.origin.y, canonicalSize.height - clamped.height))
        items[idx].frame = clamped
        imageViews[id]?.frame = clamped
        if selectedID == id {
            selectionLayer.selection = clamped
            selectionLayer.deleteBadge = deleteBadgeRect(for: clamped)
        }
        if persist { persistItems(items) }
    }

    private func removeOverlay(id: String) {
        guard let key = coordinator?.storeKey else { return }
        var items = currentItems()
        if let item = items.first(where: { $0.id == id }) {
            PageImageStore.deleteImage(key: key, fileName: item.fileName)
        }
        items.removeAll { $0.id == id }
        persistItems(items)
        selectedID = nil
        reloadOverlays()
    }

    // MARK: Finger gestures on photos

    @objc private func handleImageTap(_ g: UITapGestureRecognizer) {
        guard let content = contentView else { return }
        let p = g.location(in: content)
        // Tapping the delete badge of the selected photo removes it.
        if let id = selectedID, let f = frame(of: id), deleteBadgeRect(for: f).contains(p) {
            removeOverlay(id: id)
            return
        }
        selectOverlay(id: topImageID(at: p))
    }

    @objc private func handleImagePan(_ g: UIPanGestureRecognizer) {
        guard let content = contentView else { return }
        switch g.state {
        case .began:
            let start = g.location(in: content)
            // Undo the just-applied translation to recover the touch-down point.
            let t0 = g.translation(in: content)
            let down = CGPoint(x: start.x - t0.x, y: start.y - t0.y)
            // Grabbing a corner of the selected photo resizes; otherwise move.
            if let sid = selectedID, let f = frame(of: sid), let corner = cornerHit(f, down) {
                activeImageID = sid
                gestureStartFrame = f
                activeCorner = corner
            } else if let id = topImageID(at: down), let f = frame(of: id) {
                activeImageID = id
                gestureStartFrame = f
                activeCorner = nil
                selectOverlay(id: id)
            } else {
                activeImageID = nil
                return
            }
            canvasView.isScrollEnabled = false   // don't pan the page while dragging
        case .changed:
            guard let id = activeImageID else { return }
            setFrame(frameForPan(g.translation(in: content)), for: id, persist: false)
        case .ended, .cancelled:
            if let id = activeImageID {
                setFrame(frameForPan(g.translation(in: content)), for: id, persist: true)
            }
            activeImageID = nil
            activeCorner = nil
            canvasView.isScrollEnabled = true
        default:
            break
        }
    }

    /// The frame during a pan: a resize when a corner was grabbed, else a move.
    private func frameForPan(_ t: CGPoint) -> CGRect {
        if let corner = activeCorner {
            return resized(gestureStartFrame, corner: corner, dx: t.x, dy: t.y)
        }
        return gestureStartFrame.offsetBy(dx: t.x, dy: t.y)
    }

    /// Which corner of `frame` the point is grabbing, if any.
    private func cornerHit(_ frame: CGRect, _ point: CGPoint) -> ResizeCorner? {
        let corners: [(ResizeCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: frame.minX, y: frame.minY)),
            (.topRight, CGPoint(x: frame.maxX, y: frame.minY)),
            (.bottomLeft, CGPoint(x: frame.minX, y: frame.maxY)),
            (.bottomRight, CGPoint(x: frame.maxX, y: frame.maxY)),
        ]
        for (corner, p) in corners where hypot(point.x - p.x, point.y - p.y) <= cornerHitRadius {
            return corner
        }
        return nil
    }

    /// Aspect-locked resize about the opposite corner.
    private func resized(_ start: CGRect, corner: ResizeCorner, dx: CGFloat, dy: CGFloat) -> CGRect {
        let aspect = start.width / max(start.height, 1)
        // Anchor = the corner that stays put (opposite the one being dragged).
        let anchor: CGPoint
        let signX: CGFloat   // +1 if the dragged corner is to the right of the anchor
        let signY: CGFloat
        switch corner {
        case .bottomRight: anchor = CGPoint(x: start.minX, y: start.minY); signX = 1;  signY = 1
        case .bottomLeft:  anchor = CGPoint(x: start.maxX, y: start.minY); signX = -1; signY = 1
        case .topRight:    anchor = CGPoint(x: start.minX, y: start.maxY); signX = 1;  signY = -1
        case .topLeft:     anchor = CGPoint(x: start.maxX, y: start.maxY); signX = -1; signY = -1
        }
        let proposedW = start.width + signX * dx
        let proposedH = start.height + signY * dy
        // Follow the finger loosely while keeping the photo's aspect ratio.
        let scale = max(proposedW / start.width, proposedH / start.height)
        var w = max(minImageSide, start.width * scale)
        var h = max(minImageSide, start.height * scale)
        // Preserve aspect after the min clamp.
        if w / h > aspect { h = w / aspect } else { w = h * aspect }
        let originX = signX >= 0 ? anchor.x : anchor.x - w
        let originY = signY >= 0 ? anchor.y : anchor.y - h
        return CGRect(x: originX, y: originY, width: w, height: h)
    }

    @objc private func handleImagePinch(_ g: UIPinchGestureRecognizer) {
        guard let content = contentView else { return }
        switch g.state {
        case .began:
            let center = g.location(in: content)
            let id = (selectedID.flatMap { frame(of: $0)?.contains(center) == true ? selectedID : nil })
                ?? topImageID(at: center)
            guard let id, let f = frame(of: id) else {
                activeImageID = nil
                return
            }
            activeImageID = id
            gestureStartFrame = f
            selectOverlay(id: id)
            canvasView.isScrollEnabled = false
        case .changed:
            guard let id = activeImageID else { return }
            setFrame(pinchedFrame(g.scale), for: id, persist: false)
        case .ended, .cancelled:
            if let id = activeImageID { setFrame(pinchedFrame(g.scale), for: id, persist: true) }
            activeImageID = nil
            canvasView.isScrollEnabled = true
        default:
            break
        }
    }

    /// A two-finger pinch scales the photo about its center.
    private func pinchedFrame(_ scale: CGFloat) -> CGRect {
        let minScale = minImageSide / min(gestureStartFrame.width, gestureStartFrame.height)
        let s = max(scale, minScale)
        let newW = gestureStartFrame.width * s
        let newH = gestureStartFrame.height * s
        let center = CGPoint(x: gestureStartFrame.midX, y: gestureStartFrame.midY)
        return CGRect(x: center.x - newW / 2, y: center.y - newH / 2, width: newW, height: newH)
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if isMutatingDrawing { return }
        // Any fresh pen input means the user has moved on from a selected image.
        deselectOverlays()
        let strokes = canvasView.drawing.strokes

        // Scribble-to-erase only while an inking tool is active (not lasso/eraser).
        if canvasView.tool is PKInkingTool,
           strokes.count == lastStrokeCount + 1,
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

    // Don't steal pencil drawing / lasso gestures.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Our photo pan/pinch begin only when the finger is on a photo; otherwise
    /// they fail so the canvas scrolls/zooms normally. Tap always begins (an
    /// empty-space tap deselects).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.delegate === self else { return true }
        // Tap (deselect) and long-press (paste) may begin anywhere; only the
        // photo pan/pinch are gated to starting on a photo.
        if gestureRecognizer is UITapGestureRecognizer { return true }
        if gestureRecognizer is UILongPressGestureRecognizer { return true }
        guard let content = contentView else { return false }
        let point = gestureRecognizer.location(in: content)
        if topImageID(at: point) != nil { return true }
        // Also begin when grabbing a resize handle just outside the selection.
        if let sid = selectedID, let f = frame(of: sid), cornerHit(f, point) != nil { return true }
        return false
    }
}

// MARK: - Selection chrome

/// Non-interactive overlay that outlines the selected photo and draws a delete
/// badge. Sits above the ink; taps are handled by the page's tap recognizer.
final class SelectionOverlayView: UIView {
    var selection: CGRect? { didSet { setNeedsDisplay() } }
    var deleteBadge: CGRect? { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let sel = selection else { return }
        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(sel)

        // Corner resize handles.
        let r: CGFloat = 9
        for c in [CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.minY),
                  CGPoint(x: sel.minX, y: sel.maxY), CGPoint(x: sel.maxX, y: sel.maxY)] {
            let dot = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: dot)
        }

        guard let badge = deleteBadge else { return }
        ctx.setFillColor(UIColor.systemRed.cgColor)
        ctx.fillEllipse(in: badge)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(max(2.5, badge.width * 0.1))
        ctx.setLineCap(.round)
        let inset = badge.insetBy(dx: badge.width * 0.32, dy: badge.height * 0.32)
        ctx.move(to: CGPoint(x: inset.minX, y: inset.minY))
        ctx.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
        ctx.move(to: CGPoint(x: inset.maxX, y: inset.minY))
        ctx.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
        ctx.strokePath()
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
