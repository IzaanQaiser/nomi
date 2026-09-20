import SwiftUI

/// A directory of generated exam notebooks, kept separate from the student's own
/// blank notebooks. Tapping one opens it (to sit again, keep writing, or review
/// its grade).
struct PastExamsSheet: View {
    let project: Project
    let exams: [ProjectNotebook]
    var onOpen: (ProjectNotebook) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if exams.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(exams) { exam in
                                Button { onOpen(exam) } label: { row(exam) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .background(NomiTheme.paper.ignoresSafeArea())
            .navigationTitle("Past exams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ exam: ProjectNotebook) -> some View {
        let storageID = exam.storageID(projectID: project.id)
        let grade = ExamSessionStore.grade(storageID: storageID)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(NomiTheme.blue.opacity(0.12))
                    .frame(width: 46, height: 46)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(NomiTheme.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(exam.title)
                    .font(.headline)
                    .foregroundStyle(NomiTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(exam.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(NomiTheme.secondaryInk)
            }

            Spacer(minLength: 0)

            if let grade, grade.total > 0 {
                let pct = Int((Double(grade.awarded) / Double(grade.total) * 100).rounded())
                Text("\(pct)%")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(scoreColor(pct), in: Capsule())
            } else {
                Text("Not taken")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(NomiTheme.hairline, in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NomiTheme.secondaryInk)
        }
        .padding(16)
        .background(NomiTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            NomiView(pose: .idle)
                .frame(width: 120, height: 120)
            Text("No exams yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(NomiTheme.ink)
            Text("Tap Exam Prep to generate your first practice exam.")
                .font(.subheadline)
                .foregroundStyle(NomiTheme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scoreColor(_ pct: Int) -> Color {
        switch pct {
        case 75...: return NomiPalette.confirm
        case 50..<75: return NomiPalette.nudge
        default: return Color(red: 0.85, green: 0.16, blue: 0.20)
        }
    }
}
