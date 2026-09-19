import PDFKit
import SwiftUI

/// GoodNotes-style page background templates.
enum PaperStyle: String, CaseIterable, Identifiable {
    case blank, ruled, grid, dotted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: return "Blank"
        case .ruled: return "Ruled"
        case .grid: return "Grid"
        case .dotted: return "Dotted"
        }
    }

    var systemImage: String {
        switch self {
        case .blank: return "rectangle"
        case .ruled: return "list.dash"
        case .grid: return "grid"
        case .dotted: return "circle.grid.3x3"
        }
    }
}

/// Page background colors. Line/dot color adapts for contrast on dark pages.
enum PaperColor: String, CaseIterable, Identifiable {
    case white, cream, yellow, mint, gray, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "White"
        case .cream: return "Cream"
        case .yellow: return "Legal"
        case .mint: return "Mint"
        case .gray: return "Gray"
        case .dark: return "Dark"
        }
    }

    var isDark: Bool { self == .dark }

    var fill: UIColor {
        switch self {
        case .white: return .white
        case .cream: return UIColor(red: 0.99, green: 0.96, blue: 0.90, alpha: 1)
        case .yellow: return UIColor(red: 0.99, green: 0.97, blue: 0.80, alpha: 1)
        case .mint: return UIColor(red: 0.90, green: 0.98, blue: 0.92, alpha: 1)
        case .gray: return UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        case .dark: return UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        }
    }

    var line: UIColor {
        isDark
            ? UIColor(white: 1.0, alpha: 0.22)
            : UIColor(red: 0.45, green: 0.55, blue: 0.75, alpha: 0.5)
    }
}

/// Generates a single-page PDF for a paper template. Rendering the paper as a
/// PDF lets it flow through the same PDF + PencilKit-overlay path as imported
/// documents, so pinch-zoom scales the lines and the ink together (you're
/// really writing "on the page").
enum PaperPDF {
    /// Builds a multi-page paper document. `realPages` template pages, plus an
    /// optional trailing "add page" hint you can swipe onto to append a page.
    static func document(
        style: PaperStyle,
        fill: UIColor = .white,
        line: UIColor = UIColor(red: 0.45, green: 0.55, blue: 0.75, alpha: 0.5),
        realPages: Int = 1,
        includeAddHint: Bool = false,
        // High base resolution so ink/lines stay crisp when zoomed in. The page
        // is displayed scaled-to-fit, so zooming reveals native detail rather
        // than magnifying a low-res raster.
        size: CGSize = CGSize(width: 2048, height: 2732)
    ) -> PDFDocument {
        let bounds = CGRect(origin: .zero, size: size)
        let total = max(1, realPages) + (includeAddHint ? 1 : 0)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for page in 0..<total {
                ctx.beginPage()
                let isHint = includeAddHint && page == total - 1
                drawTemplate(style: style, size: size, cg: ctx.cgContext, fill: fill, line: line)
                if isHint { drawAddHint(size: size, cg: ctx.cgContext, color: line) }
            }
        }
        return PDFDocument(data: data) ?? PDFDocument()
    }

    /// Renders a single paper page to a high-resolution bitmap. Used as the
    /// background *inside* a zooming PKCanvasView so ink (vector) stays crisp
    /// and the paper scales with it.
    static func image(
        style: PaperStyle,
        fill: UIColor,
        line: UIColor,
        size: CGSize,
        scale: CGFloat = 3
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            drawTemplate(style: style, size: size, cg: ctx.cgContext, fill: fill, line: line)
        }
    }

    private static func drawTemplate(
        style: PaperStyle, size: CGSize, cg: CGContext, fill: UIColor, line: UIColor
    ) {
        fill.setFill()
        cg.fill(CGRect(origin: .zero, size: size))

        guard style != .blank else { return }
        // Scale drawing metrics to the page resolution so the on-screen density
        // and line weight look the same regardless of base resolution.
        let scale = size.width / 1024
        let spacing: CGFloat = 40 * scale
        line.setStroke()
        cg.setLineWidth(max(1, 1 * scale))

        switch style {
        case .blank:
            break
        case .ruled:
            var y = spacing
            while y < size.height {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            cg.strokePath()
        case .grid:
            var x = spacing
            while x < size.width {
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = spacing
            while y < size.height {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            cg.strokePath()
        case .dotted:
            line.setFill()
            let r = 1.5 * scale
            var y = spacing
            while y < size.height {
                var x = spacing
                while x < size.width {
                    cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += spacing
                }
                y += spacing
            }
        }
    }

    /// A faint centered "+" so the trailing page reads as "swipe to add a page".
    private static func drawAddHint(size: CGSize, cg: CGContext, color: UIColor) {
        let scale = size.width / 1024
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 70 * scale
        color.setStroke()
        cg.setLineWidth(6 * scale)
        cg.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2))
        cg.strokePath()
        let arm: CGFloat = 34 * scale
        cg.move(to: CGPoint(x: center.x - arm, y: center.y))
        cg.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        cg.move(to: CGPoint(x: center.x, y: center.y - arm))
        cg.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        cg.strokePath()
    }
}

/// Draws the selected paper template. Rendered behind a transparent canvas so
/// ink appears on top of the lines/dots.
struct PaperBackground: View {
    let style: PaperStyle
    var spacing: CGFloat = 30

    private var lineColor: Color {
        Color(.sRGB, red: 0.45, green: 0.55, blue: 0.75, opacity: 0.35)
    }

    var body: some View {
        Canvas { context, size in
            guard style != .blank else { return }
            let s = spacing

            switch style {
            case .blank:
                break
            case .ruled:
                var y = s
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(lineColor), lineWidth: 1)
                    y += s
                }
            case .grid:
                var x: CGFloat = s
                while x < size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(lineColor), lineWidth: 1)
                    x += s
                }
                var y: CGFloat = s
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(lineColor), lineWidth: 1)
                    y += s
                }
            case .dotted:
                let r: CGFloat = 1.4
                var y: CGFloat = s
                while y < size.height {
                    var x: CGFloat = s
                    while x < size.width {
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(lineColor))
                        x += s
                    }
                    y += s
                }
            }
        }
        .background(Color(.systemBackground))
    }
}
