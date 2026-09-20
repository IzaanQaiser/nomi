import PencilKit
import SwiftUI

/// Drives a live exam sitting: the countdown, the timed nudges, and the phase
/// (writing → grading → results). Grading itself is kicked off by the view,
/// which owns the page bitmaps; the controller just holds state.
@MainActor
final class ExamController: ObservableObject {
    enum Phase: Equatable {
        case writing
        case grading
        case done(ExamGrade)
        case failed(String)
    }

    let exam: GeneratedExam?
    let storageID: String

    @Published var remaining: TimeInterval = 0
    @Published var phase: Phase = .writing
    /// Transient time-remaining nudge (auto-clears).
    @Published var nudge: String?

    private var deadline: Date = .distantFuture
    private var timer: Timer?
    private var firedThresholds: Set<Int> = []

    /// Nudge thresholds in seconds remaining.
    private let thresholds: [Int] = [3600, 1800, 600, 60]

    var isActive: Bool { exam != nil }

    init(exam: GeneratedExam?, storageID: String) {
        self.exam = exam
        self.storageID = storageID
        guard let exam else { return }
        // Re-viewing an already-graded exam jumps straight to results.
        if let saved = ExamSessionStore.grade(storageID: storageID) {
            phase = .done(saved)
            return
        }
        deadline = ExamSessionStore.startIfNeeded(
            storageID: storageID, durationMinutes: exam.durationMinutes)
        remaining = max(0, deadline.timeIntervalSinceNow)
    }

    func start() {
        guard isActive, case .writing = phase, timer == nil else { return }
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        remaining = max(0, deadline.timeIntervalSinceNow)
        checkNudges()
        if remaining <= 0 { beginGrading() }
    }

    private func checkNudges() {
        let secs = Int(remaining.rounded())
        for threshold in thresholds where !firedThresholds.contains(threshold) && secs <= threshold {
            firedThresholds.insert(threshold)
            nudge = Self.nudgeText(forSecondsRemaining: threshold)
            let shown = nudge
            // Auto-dismiss the bubble after a few seconds.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self.nudge == shown { self.nudge = nil }
            }
        }
    }

    static func nudgeText(forSecondsRemaining s: Int) -> String {
        switch s {
        case 3600: return "One hour left — pace yourself."
        case 1800: return "Halfway warning: 30 minutes to go."
        case 600:  return "10 minutes left. Wrap up your working."
        case 60:   return "One minute! Put your pencil down soon."
        default:   return "\(s / 60) minutes left."
        }
    }

    /// Called on expiry, or when the student hands in early.
    func beginGrading() {
        guard case .writing = phase else { return }
        stop()
        nudge = nil
        phase = .grading
    }

    func complete(with grade: ExamGrade) {
        ExamSessionStore.saveGrade(grade, storageID: storageID)
        phase = .done(grade)
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }

    /// Retry grading after a failure.
    func retryGrading() {
        if case .failed = phase { phase = .grading }
    }

    var clock: String {
        let s = max(0, Int(remaining.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }

    /// Runs low in the last five minutes (drives the red pulse).
    var isRunningLow: Bool { remaining <= 300 }
}

/// Renders each notebook page (background + ink) to a base64 JPEG for grading.
enum ExamPageRenderer {
    static func renderPages(
        storeKey: String,
        pageCount: Int,
        canonicalSize: (Int) -> CGSize,
        background: (Int) -> UIImage?
    ) -> [String] {
        let drawings = PDFNoteStore.loadDrawings(key: storeKey)
        var pages: [String] = []
        for i in 0..<max(0, pageCount) {
            let size = canonicalSize(i)
            guard size.width > 0, size.height > 0 else { continue }
            let scale = min(2, max(1, 1100 / size.width))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                background(i)?.draw(in: CGRect(origin: .zero, size: size))
                if let data = drawings[i], let drawing = try? PKDrawing(data: data) {
                    drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
                        .draw(in: CGRect(origin: .zero, size: size))
                }
            }
            if let jpeg = image.jpegData(compressionQuality: 0.7) {
                pages.append(jpeg.base64EncodedString())
            }
        }
        return pages
    }
}
