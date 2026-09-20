import SwiftUI

/// Full-screen "Nomi is building your exam" state. A large thinking Nomi with
/// course symbols orbiting him while the (slow) generation request runs.
struct ExamLoadingView: View {
    /// Optional caption override; otherwise cycles through `phrases`.
    var caption: String?
    /// Cycling status lines; defaults to the exam-building set.
    var phrases: [String] = [
        "Reading your notes…",
        "Studying past exams…",
        "Weighing the tricky topics…",
        "Setting fair questions…",
        "Leaving you room to write…",
    ]

    private let orbiting: [String] = [
        "function", "sum", "pencil.and.outline", "doc.text",
        "ruler", "x.squareroot", "chart.xyaxis.line", "highlighter",
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [NomiTheme.paper, NomiTheme.blue.opacity(0.10)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    orbit(t: t)
                    NomiView(pose: .thinking)
                        .frame(width: 220, height: 220)
                        .scaleEffect(1 + 0.02 * sin(t * 1.6))
                }
                .frame(width: 320, height: 320)
            }

            VStack {
                Spacer()
                Text(caption ?? phrase)
                    .font(.headline)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .transition(.opacity)
                    .id(caption ?? phrase)
                    .animation(.easeInOut(duration: 0.4), value: phrase)
                    .padding(.bottom, 64)
            }
        }
    }

    /// Symbols evenly spaced on a ring, slowly rotating, each bobbing a little.
    private func orbit(t: Double) -> some View {
        let radius: CGFloat = 140
        return ZStack {
            ForEach(Array(orbiting.enumerated()), id: \.offset) { i, symbol in
                let base = Double(i) / Double(orbiting.count) * 2 * .pi
                let angle = base + t * 0.35
                let wobble = 1 + 0.06 * sin(t * 1.3 + base * 3)
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(NomiTheme.blue.opacity(0.75))
                    .offset(
                        x: CGFloat(cos(angle)) * radius * wobble,
                        y: CGFloat(sin(angle)) * radius * wobble
                    )
                    .opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(t * 1.1 + base)))
            }
        }
    }

    /// Advance the caption every ~2.2s off the wall clock (no extra state).
    private var phrase: String {
        let idx = Int(Date().timeIntervalSinceReferenceDate / 2.2) % phrases.count
        return phrases[idx]
    }
}

#Preview {
    ExamLoadingView()
}
