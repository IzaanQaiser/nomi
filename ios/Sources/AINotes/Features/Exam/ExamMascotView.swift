import SwiftUI

/// Nomi during an exam: present and watching, but silent — he only speaks up
/// with the timed remaining-time nudges from the controller.
struct ExamMascotView: View {
    @ObservedObject var controller: ExamController

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let nudge = controller.nudge {
                Text(nudge)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: 220, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.red.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            NomiView(pose: .idle)
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: controller.nudge)
    }
}
