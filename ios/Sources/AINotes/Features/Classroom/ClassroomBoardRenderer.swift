import SwiftUI

/// Renders Nomi's validated board protocol into one deterministic viewport.
/// This layer is visual-only and intentionally does not accept touches.
struct ClassroomBoardRenderer: View {
    let actions: [ClassroomBoardAction]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            for action in actions {
                draw(action, in: &context, size: size)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(
        _ action: ClassroomBoardAction,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        switch action {
        case let .writeText(value):
            drawText(value, in: &context, size: size)
        case let .drawLine(value):
            strokeLine(
                from: point(value.start, size: size),
                to: point(value.end, size: size),
                style: value.style,
                in: &context,
                size: size
            )
        case let .drawArrow(value):
            drawArrow(
                from: point(value.start, size: size),
                to: point(value.end, size: size),
                in: &context,
                size: size
            )
        case let .drawRectangle(value):
            drawRectangle(value, in: &context, size: size)
        case let .drawAxes(value):
            drawAxes(value, in: &context, size: size)
        case let .plotPolyline(value):
            drawPolyline(value, in: &context, size: size)
        case let .highlight(value):
            let rect = frame(value.frame, size: size)
            context.fill(
                Path(roundedRect: rect, cornerRadius: max(4, lineWidth(size) * 2)),
                with: .color(Color.orange.opacity(0.18))
            )
        case .clear, .unsupported:
            break
        }
    }

    private func drawText(
        _ action: ClassroomWriteTextAction,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let origin = point(action.position, size: size)
        let available = CGSize(
            width: max(1, size.width - origin.x),
            height: max(1, size.height - origin.y)
        )
        let text = Text(action.text)
            .font(font(for: action.style, size: size))
            .foregroundStyle(textColor(for: action.style))
        let resolved = context.resolve(text)
        let measured = resolved.measure(in: available)
        let rect = CGRect(
            origin: origin,
            size: CGSize(
                width: min(available.width, max(1, measured.width)),
                height: min(available.height, max(1, measured.height))
            )
        )
        context.draw(resolved, in: rect)
    }

    private func strokeLine(
        from start: CGPoint,
        to end: CGPoint,
        style: String,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(
            path,
            with: .color(NomiTheme.ink),
            style: strokeStyle(style, size: size)
        )
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        strokeLine(from: start, to: end, style: "solid", in: &context, size: size)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.001, hypot(dx, dy))
        let unit = CGVector(dx: dx / length, dy: dy / length)
        let perpendicular = CGVector(dx: -unit.dy, dy: unit.dx)
        let headLength = min(18, max(9, min(size.width, size.height) * 0.025))
        let headWidth = headLength * 0.55
        let base = CGPoint(
            x: end.x - unit.dx * headLength,
            y: end.y - unit.dy * headLength
        )
        let left = CGPoint(
            x: base.x + perpendicular.dx * headWidth,
            y: base.y + perpendicular.dy * headWidth
        )
        let right = CGPoint(
            x: base.x - perpendicular.dx * headWidth,
            y: base.y - perpendicular.dy * headWidth
        )

        var head = Path()
        head.move(to: left)
        head.addLine(to: end)
        head.addLine(to: right)
        context.stroke(
            head,
            with: .color(NomiTheme.ink),
            style: StrokeStyle(lineWidth: lineWidth(size), lineCap: .round, lineJoin: .round)
        )
    }

    private func drawRectangle(
        _ action: ClassroomDrawRectangleAction,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let rect = frame(action.frame, size: size)
        let path = Path(roundedRect: rect, cornerRadius: max(5, lineWidth(size) * 2.5))
        if action.style == "filled" {
            context.fill(path, with: .color(NomiTheme.blue.opacity(0.10)))
        }
        context.stroke(
            path,
            with: .color(NomiTheme.ink),
            style: StrokeStyle(lineWidth: lineWidth(size), lineJoin: .round)
        )
    }

    private func drawAxes(
        _ action: ClassroomDrawAxesAction,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let rect = frame(action.frame, size: size)
        let origin = CGPoint(x: rect.minX, y: rect.maxY)
        drawArrow(
            from: origin,
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            in: &context,
            size: size
        )
        drawArrow(
            from: origin,
            to: CGPoint(x: rect.minX, y: rect.minY),
            in: &context,
            size: size
        )

        if !action.xLabel.isEmpty {
            drawLabel(
                action.xLabel,
                at: CGPoint(x: rect.maxX, y: rect.maxY),
                anchor: .bottomTrailing,
                in: &context,
                size: size
            )
        }
        if !action.yLabel.isEmpty {
            drawLabel(
                action.yLabel,
                at: CGPoint(x: rect.minX, y: rect.minY),
                anchor: .topLeading,
                in: &context,
                size: size
            )
        }
    }

    private func drawPolyline(
        _ action: ClassroomPlotPolylineAction,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let first = action.points.first else { return }
        var path = Path()
        path.move(to: point(first, size: size))
        for value in action.points.dropFirst() {
            path.addLine(to: point(value, size: size))
        }
        context.stroke(
            path,
            with: .color(NomiTheme.blue),
            style: strokeStyle(action.style, size: size)
        )
    }

    private func drawLabel(
        _ value: String,
        at position: CGPoint,
        anchor: UnitPoint,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let text = Text(value)
            .font(.system(size: max(12, min(size.width, size.height) * 0.026), weight: .semibold))
            .foregroundStyle(NomiTheme.secondaryInk)
        context.draw(context.resolve(text), at: position, anchor: anchor)
    }

    private func point(_ value: ClassroomBoardPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: clamped(value.x) * size.width,
            y: clamped(value.y) * size.height
        )
    }

    private func frame(_ value: ClassroomBoardFrame, size: CGSize) -> CGRect {
        CGRect(
            x: clamped(value.x) * size.width,
            y: clamped(value.y) * size.height,
            width: clamped(value.width) * size.width,
            height: clamped(value.height) * size.height
        ).intersection(CGRect(origin: .zero, size: size))
    }

    private func clamped(_ value: Double) -> CGFloat {
        CGFloat(min(1, max(0, value)))
    }

    private func lineWidth(_ size: CGSize) -> CGFloat {
        min(3.5, max(1.8, min(size.width, size.height) * 0.004))
    }

    private func strokeStyle(_ style: String, size: CGSize) -> StrokeStyle {
        let width = lineWidth(size)
        return StrokeStyle(
            lineWidth: width,
            lineCap: .round,
            lineJoin: .round,
            dash: style == "dashed" ? [width * 4, width * 3] : []
        )
    }

    private func font(for style: String, size: CGSize) -> Font {
        let scale = min(size.width, size.height)
        switch style {
        case "heading":
            return .system(size: max(18, scale * 0.050), weight: .bold)
        case "equation":
            return .system(size: max(17, scale * 0.044), weight: .medium, design: .monospaced)
        case "label":
            return .system(size: max(12, scale * 0.030), weight: .semibold)
        case "emphasis":
            return .system(size: max(16, scale * 0.040), weight: .bold)
        default:
            return .system(size: max(15, scale * 0.038), weight: .regular)
        }
    }

    private func textColor(for style: String) -> Color {
        style == "emphasis" ? NomiTheme.blue : NomiTheme.ink
    }
}
