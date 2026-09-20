import PDFKit
import UIKit

/// Renders a `GeneratedExam` into a printable PDF with real writing space under
/// each question. The PDF becomes a notebook background, so the student writes
/// their answers directly on top in ink.
enum ExamPDFRenderer {
    // US Letter at 72dpi.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54
    private static let lineGap: CGFloat = 30      // vertical writing space per "line"

    static func makePDF(from exam: GeneratedExam) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        return renderer.pdfData { ctx in
            var cursor = Cursor(ctx: ctx, bounds: bounds)
            cursor.beginPage()

            cursor.draw(exam.title, font: .systemFont(ofSize: 22, weight: .bold), spacingAfter: 4)
            let meta = "\(exam.totalMarks) marks · \(exam.durationMinutes) minutes"
            cursor.draw(meta, font: .systemFont(ofSize: 12, weight: .semibold),
                        color: .darkGray, spacingAfter: 10)
            if let instructions = exam.instructions, !instructions.isEmpty {
                cursor.draw(instructions, font: .italicSystemFont(ofSize: 12),
                            color: .darkGray, spacingAfter: 12)
            }
            cursor.rule(spacingAfter: 16)

            for section in exam.sections {
                cursor.reserve(60)
                cursor.draw(section.title, font: .systemFont(ofSize: 16, weight: .bold),
                            spacingAfter: 4)
                if let si = section.instructions, !si.isEmpty {
                    cursor.draw(si, font: .italicSystemFont(ofSize: 11.5),
                                color: .darkGray, spacingAfter: 8)
                }
                cursor.pad(4)

                for q in section.questions {
                    cursor.reserve(40 + lineGap)   // keep prompt with some space below
                    cursor.drawQuestion(number: q.number, prompt: q.prompt, marks: q.marks)
                    cursor.answerSpace(q.answerLines)
                    cursor.pad(14)
                }
                cursor.pad(8)
            }
        }
    }

    /// A little pagination cursor over the PDF context.
    private struct Cursor {
        let ctx: UIGraphicsPDFRendererContext
        let bounds: CGRect
        var y: CGFloat = 0

        init(ctx: UIGraphicsPDFRendererContext, bounds: CGRect) {
            self.ctx = ctx
            self.bounds = bounds
        }

        var contentWidth: CGFloat { bounds.width - margin * 2 }
        var maxY: CGFloat { bounds.height - margin }

        mutating func beginPage() {
            ctx.beginPage()
            y = margin
        }

        /// Start a new page if `needed` points won't fit.
        mutating func reserve(_ needed: CGFloat) {
            if y + needed > maxY { beginPage() }
        }

        mutating func pad(_ amount: CGFloat) { y += amount }

        mutating func draw(_ text: String, font: UIFont, color: UIColor = .black,
                           spacingAfter: CGFloat = 0) {
            let attributed = NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: color])
            drawAttributed(attributed, spacingAfter: spacingAfter)
        }

        mutating func drawAttributed(_ text: NSAttributedString, spacingAfter: CGFloat = 0) {
            let bounding = text.boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            if y + bounding.height > maxY { beginPage() }
            text.draw(
                with: CGRect(x: margin, y: y, width: contentWidth, height: bounding.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += bounding.height + spacingAfter
        }

        /// The marks are appended to the end of the prompt as bold "[N marks]",
        /// same font size, so they can never sit on top of the question text.
        mutating func drawQuestion(number: String, prompt: String, marks: Int) {
            let font = UIFont.systemFont(ofSize: 13, weight: .medium)
            let bold = UIFont.systemFont(ofSize: 13, weight: .bold)
            let unit = marks == 1 ? "mark" : "marks"
            let line = NSMutableAttributedString(
                string: "\(number).  \(prompt)",
                attributes: [.font: font, .foregroundColor: UIColor.black])
            line.append(NSAttributedString(
                string: "  [\(marks) \(unit)]",
                attributes: [.font: bold, .foregroundColor: UIColor.black]))
            drawAttributed(line, spacingAfter: 8)
        }

        /// Blank writing space (no rules), sized by the question, split across
        /// pages when it doesn't all fit.
        mutating func answerSpace(_ lines: Int) {
            var remaining = CGFloat(max(1, lines)) * lineGap
            while remaining > 0 {
                let available = maxY - y
                if available <= 1 { beginPage(); continue }
                let take = min(remaining, available)
                y += take
                remaining -= take
                if remaining > 0 { beginPage() }
            }
        }

        mutating func rule(spacingAfter: CGFloat = 0) {
            guard let cg = UIGraphicsGetCurrentContext() else { return }
            cg.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
            cg.setLineWidth(1)
            cg.move(to: CGPoint(x: margin, y: y))
            cg.addLine(to: CGPoint(x: bounds.width - margin, y: y))
            cg.strokePath()
            y += spacingAfter
        }
    }
}
