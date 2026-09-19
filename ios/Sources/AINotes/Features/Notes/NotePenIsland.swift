import PencilKit
import SwiftUI

/// Drives the notebook's drawing tools in place of Apple's `PKToolPicker`, so the
/// chrome matches the rest of the app. Shared between the SwiftUI island and the
/// `InkPagerView` coordinator, which applies `pkTool` to the active canvas and
/// services the undo/redo requests.
@MainActor
final class NoteToolController: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, pencil, marker, monoline, eraser, lasso
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .pencil: return "pencil"
            case .marker: return "highlighter"
            case .monoline: return "pencil.line"
            case .eraser: return "eraser"
            case .lasso: return "lasso"
            }
        }

        var label: String {
            switch self {
            case .pen: return "Pen"
            case .pencil: return "Pencil"
            case .marker: return "Marker"
            case .monoline: return "Monoline"
            case .eraser: return "Eraser"
            case .lasso: return "Select"
            }
        }

        var isInking: Bool {
            switch self {
            case .pen, .pencil, .marker, .monoline: return true
            case .eraser, .lasso: return false
            }
        }
    }

    /// Which screen edge the floating island is parked against.
    enum DockEdge: String {
        case left, right, top, bottom
        var isVertical: Bool { self == .left || self == .right }
    }

    @Published var tool: Tool = .pen
    @Published var color: Color = .black
    @Published var width: CGFloat = 5
    /// Eraser removes whole strokes (object) vs. pixels (bitmap).
    @Published var eraserIsObject = true
    @Published var dock: DockEdge = .bottom
    /// Whether the expanded color/width tray is showing.
    @Published var showsDetail = false

    // Fire-and-forget requests picked up by the canvas coordinator.
    @Published var undoNonce = 0
    @Published var redoNonce = 0
    @Published var canUndo = false
    @Published var canRedo = false

    static let palette: [Color] = [
        .black,
        NomiTheme.blue,
        Color(red: 0.85, green: 0.16, blue: 0.20),   // red
        Color(red: 0.13, green: 0.62, blue: 0.35),   // green
        Color(red: 0.95, green: 0.61, blue: 0.07),   // amber
        Color(red: 0.52, green: 0.24, blue: 0.80),   // purple
    ]
    static let widths: [CGFloat] = [2, 5, 9, 16]

    /// The PencilKit tool for the current selection.
    var pkTool: PKTool {
        let ui = UIColor(color)
        switch tool {
        case .pen: return PKInkingTool(.pen, color: ui, width: width)
        case .pencil: return PKInkingTool(.pencil, color: ui, width: width)
        case .marker: return PKInkingTool(.marker, color: ui, width: width)
        case .monoline: return PKInkingTool(.monoline, color: ui, width: width)
        case .eraser: return PKEraserTool(eraserIsObject ? .vector : .bitmap)
        case .lasso: return PKLassoTool()
        }
    }

    func requestUndo() { undoNonce &+= 1 }
    func requestRedo() { redoNonce &+= 1 }
}

// MARK: - Floating tool island

/// A compact, draggable tool palette that follows the app's design. Swipe it to
/// any edge (left/right/top/bottom); tap the swatch to reveal colors + widths.
struct PenIslandView: View {
    @ObservedObject var tools: NoteToolController
    @GestureState private var drag: CGSize = .zero

    private let barPadding: CGFloat = 16
    private let space = "penIslandArea"

    var body: some View {
        GeometryReader { geo in
            // Only the bar itself is interactive; empty area passes touches to the
            // canvas below (the gesture is attached before the expanding frame).
            island
                .offset(drag)
                .gesture(
                    DragGesture(coordinateSpace: .named(space))
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in snap(to: value.location, in: geo.size) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .padding(barPadding)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tools.dock)
        }
        .coordinateSpace(name: space)
    }

    private var alignment: Alignment {
        switch tools.dock {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    private func snap(to point: CGPoint, in size: CGSize) {
        let dLeft = point.x
        let dRight = size.width - point.x
        let dTop = point.y
        let dBottom = size.height - point.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if nearest == dLeft { tools.dock = .left }
            else if nearest == dRight { tools.dock = .right }
            else if nearest == dTop { tools.dock = .top }
            else { tools.dock = .bottom }
        }
    }

    // MARK: Island body

    private var island: some View {
        let layout = tools.dock.isVertical
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            grip
            ForEach(NoteToolController.Tool.allCases) { tool in
                toolButton(tool)
            }
            separator
            swatchButton
            if tools.showsDetail {
                detailTray
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(NomiTheme.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .fixedSize()
    }

    private var grip: some View {
        Image(systemName: tools.dock.isVertical ? "line.3.horizontal" : "line.3.horizontal")
            .rotationEffect(.degrees(tools.dock.isVertical ? 90 : 0))
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 30, height: 30)
    }

    private func toolButton(_ tool: NoteToolController.Tool) -> some View {
        let selected = tools.tool == tool
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if tool == .eraser && tools.tool == .eraser {
                    tools.eraserIsObject.toggle()   // second tap flips eraser mode
                }
                tools.tool = tool
                if tool.isInking { /* keep detail as-is */ }
            }
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? NomiTheme.blue : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
    }

    private var separator: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(NomiTheme.hairline)
            .frame(
                width: tools.dock.isVertical ? 22 : 1,
                height: tools.dock.isVertical ? 1 : 22
            )
    }

    /// The current color / eraser mode, tap to expand the tray.
    private var swatchButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                tools.showsDetail.toggle()
            }
        } label: {
            Circle()
                .fill(tools.tool == .eraser ? Color.secondary.opacity(0.35) : tools.color)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .overlay(Circle().strokeBorder(NomiTheme.hairline, lineWidth: 0.5))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colors and width")
    }

    // MARK: Expanded tray (colors + widths)

    private var detailTray: some View {
        let layout = tools.dock.isVertical
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            if tools.tool == .eraser {
                eraserModePicker
            } else {
                colorRow
                separator
                widthRow
            }
        }
        .padding(tools.dock.isVertical ? .vertical : .horizontal, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var colorRow: some View {
        let layout = tools.dock.isVertical
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(Array(NoteToolController.palette.enumerated()), id: \.offset) { _, c in
                Button {
                    tools.color = c
                    if !tools.tool.isInking { tools.tool = .pen }
                } label: {
                    Circle()
                        .fill(c)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().strokeBorder(NomiTheme.blue,
                                                  lineWidth: colorMatches(c) ? 2.5 : 0)
                        )
                        .padding(2)
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: $tools.color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26, height: 26)
        }
    }

    private func colorMatches(_ c: Color) -> Bool {
        UIColor(c).cgColor == UIColor(tools.color).cgColor
    }

    private var widthRow: some View {
        let layout = tools.dock.isVertical
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(Array(NoteToolController.widths.enumerated()), id: \.offset) { _, w in
                Button {
                    tools.width = w
                    if !tools.tool.isInking { tools.tool = .pen }
                } label: {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: dotSize(w), height: dotSize(w))
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(tools.width == w ? NomiTheme.blue.opacity(0.18) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dotSize(_ w: CGFloat) -> CGFloat { max(6, min(22, 6 + w)) }

    private var eraserModePicker: some View {
        let layout = tools.dock.isVertical
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            modeChip("Object", on: tools.eraserIsObject) { tools.eraserIsObject = true }
            modeChip("Pixel", on: !tools.eraserIsObject) { tools.eraserIsObject = false }
        }
    }

    private func modeChip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(
                    Capsule().fill(on ? NomiTheme.blue : Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
    }
}
