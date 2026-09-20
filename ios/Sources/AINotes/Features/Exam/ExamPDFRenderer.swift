import PDFKit
import UIKit

/// Renders a `GeneratedExam` into a printable PDF with real writing space under
/// each question. The PDF becomes a notebook background, so the student writes
/// their answers directly on top in ink.
enum ExamPDFRenderer {
    // US Letter at 72dpi.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54
    private static let lineGap: CGFloat = 30      // space per ruled answer line
    private static let ruleColor = UIColor(white: 0.72, alpha: 1)

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
                    cursor.reserve(40 + lineGap)   // keep prompt with at least one line
                    let prompt = "\(q.number).  \(q.prompt)"
                    let marks = "[\(q.marks) \(q.marks == 1 ? "mark" : "marks")]"
                    cursor.drawQuestion(prompt: prompt, marks: marks)
                    cursor.answerLines(q.answerLines)
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
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let rect = CGRect(x: margin, y: y, width: contentWidth, height: .greatestFiniteMagnitude)
            let bounding = (text as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil)
            if y + bounding.height > maxY { beginPage() }
            (text as NSString).draw(
                with: CGRect(x: margin, y: y, width: contentWidth, height: bounding.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil)
            _ = rect
            y += bounding.height + spacingAfter
        }

        /// Question prompt on the left, marks pinned to the right of the first line.
        mutating func drawQuestion(prompt: String, marks: String) {
            let font = UIFont.systemFont(ofSize: 13, weight: .medium)
            let marksFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
            let marksAttrs: [NSAttributedString.Key: Any] = [.font: marksFont, .foregroundColor: UIColor.darkGray]
            let marksSize = (marks as NSString).size(withAttributes: marksAttrs)
            (marks as NSString).draw(at: CGPoint(x: bounds.width - margin - marksSize.width, y: y),
                                     withAttributes: marksAttrs)
            draw(prompt, font: font, spacingAfter: 8)
        }

        mutating func answerLines(_ count: Int) {
            guard count > 0, let cg = UIGraphicsGetCurrentContext() else { return }
            cg.setStrokeColor(ruleColor.cgColor)
            cg.setLineWidth(0.5)
            for _ in 0..<count {
                if y + lineGap > maxY { beginPage() }
                y += lineGap
                cg.move(to: CGPoint(x: margin, y: y))
                cg.addLine(to: CGPoint(x: bounds.width - margin, y: y))
                cg.strokePath()
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
