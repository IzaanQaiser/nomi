import SwiftUI

/// The graded-exam results screen: a scrollable grade breakdown on the left and
/// a big Nomi on the right whose mood reflects how the sitting went.
struct ExamBreakdownView: View {
    let exam: GeneratedExam
    let grade: ExamGrade
    var onDone: () -> Void

    private var percent: Double {
        grade.total > 0 ? Double(grade.awarded) / Double(grade.total) * 100 : 0
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: min(430, max(340, proxy.size.width * 0.4)))

                Rectangle().fill(NomiTheme.hairline).frame(width: 1)

                nomiPanel(height: proxy.size.height)
            }
        }
        .background(NomiTheme.paper.ignoresSafeArea())
        .preferredColorScheme(.light)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Exam review")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NomiTheme.secondaryInk)
                Text(exam.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(NomiTheme.ink)
                    .lineLimit(2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scoreCard
                    Text("Question by question")
                        .font(.headline)
                        .foregroundStyle(NomiTheme.ink)
                    VStack(spacing: 10) {
                        ForEach(grade.questions, id: \.number) { q in
                            questionRow(q)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            Button(action: onDone) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(NomiTheme.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(20)
        }
        .background(NomiTheme.surface)
    }

    private var scoreCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                gradeRing
                VStack(alignment: .leading, spacing: 6) {
                    Text(letterGrade)
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(tint)
                    Text("\(grade.awarded) / \(grade.total) marks")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NomiTheme.secondaryInk)
                }
                Spacer(minLength: 0)
            }

            progressBar

            if !grade.summary.isEmpty {
                Text(grade.summary)
                    .font(.callout)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .background(NomiTheme.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var gradeRing: some View {
        ZStack {
            Circle()
                .stroke(NomiTheme.hairline, lineWidth: 12)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, percent / 100)))
                .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(NomiTheme.ink)
                Text("%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NomiTheme.secondaryInk)
            }
        }
        .frame(width: 104, height: 104)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NomiTheme.hairline)
                Capsule().fill(tint)
                    .frame(width: max(8, geo.size.width * min(1, percent / 100)))
            }
        }
        .frame(height: 12)
    }

    private func questionRow(_ q: GradedQuestion) -> some View {
        let ratio = q.marks > 0 ? Double(q.awarded) / Double(q.marks) : 0
        let color = markColor(ratio)
        return HStack(alignment: .top, spacing: 12) {
            Text(q.number)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("\(q.awarded) / \(q.marks) marks")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.ink)
                if !q.feedback.isEmpty {
                    Text(q.feedback)
                        .font(.footnote)
                        .foregroundStyle(NomiTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if q.awarded < q.marks,
                   let answer = q.correctAnswer,
                   !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption2)
                            .foregroundStyle(NomiTheme.blue)
                        Text(answer)
                            .font(.footnote)
                            .foregroundStyle(NomiTheme.ink.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 0.5)
        )
    }

    // MARK: Nomi panel

    private func nomiPanel(height: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.10), NomiTheme.paper],
                startPoint: .top, endPoint: .bottom
            )
            VStack(spacing: 18) {
                NomiView(pose: pose)
                    .frame(height: height * 0.8)
                Text(moodLine)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(NomiTheme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    // MARK: Grade → presentation

    private var pose: NomiPose {
        switch percent {
        case 90...: return .confirm
        case 75..<90: return .idle
        case 60..<75: return .thinking
        case 50..<60: return .nudge
        default: return .sad
        }
    }

    private var moodLine: String {
        switch percent {
        case 90...: return "Outstanding — you crushed it! 🎉"
        case 75..<90: return "Strong work. You clearly know this."
        case 60..<75: return "Solid effort — a few things to tighten up."
        case 50..<60: return "You scraped through. Let's review the gaps."
        default: return "Rough one. Don't worry — we'll fix these together."
        }
    }

    private var letterGrade: String {
        switch percent {
        case 90...: return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        case 60..<70: return "D"
        case 50..<60: return "E"
        default: return "F"
        }
    }

    private var tint: Color {
        switch percent {
        case 75...: return NomiPalette.confirm
        case 50..<75: return NomiPalette.nudge
        default: return Color(red: 0.85, green: 0.16, blue: 0.20)
        }
    }

    private func markColor(_ ratio: Double) -> Color {
        switch ratio {
        case 0.75...: return NomiPalette.confirm
        case 0.4..<0.75: return NomiPalette.nudge
        default: return Color(red: 0.85, green: 0.16, blue: 0.20)
        }
    }
}
