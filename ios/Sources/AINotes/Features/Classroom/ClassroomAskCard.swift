import SwiftUI

/// Voice-only Q&A rail. Ask Nomi starts the mic; silence ends the turn.
struct ClassroomAskCard: View {
    @Bindable var session: ClassroomSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(session.visibleExchanges) { turn in
                        VStack(alignment: .leading, spacing: 6) {
                            labeled("You", turn.question)
                            labeled("Nomi", turn.answer)
                        }
                    }

                    if session.isListening {
                        listeningStatus
                    } else if session.isSendingAsk {
                        HStack(spacing: 8) {
                            ProgressView().tint(NomiTheme.blue)
                            Text("Thinking…")
                                .font(.subheadline)
                                .foregroundStyle(NomiTheme.secondaryInk)
                        }
                    } else if session.player.isSpeakingAnswer {
                        Text("Nomi is answering…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NomiTheme.blue)
                    } else if session.visibleExchanges.isEmpty, session.askError == nil {
                        Text("Ask your question out loud.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NomiTheme.secondaryInk)
                    }

                    if let askError = session.askError {
                        Text(askError)
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                        Button("Try again") {
                            Task { await session.retryAskListening() }
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(NomiTheme.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Continue lesson") {
                session.continueLesson()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(NomiTheme.blue, in: Capsule())
            .accessibilityHint("Resume this slide")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            NomiTheme.surface,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.18), value: session.isSendingAsk)
        .animation(.easeInOut(duration: 0.18), value: session.isListening)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask Nomi")
    }

    private var listeningStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(NomiTheme.blue, in: Circle())
                    .symbolEffect(.pulse, isActive: true)
                Text("Listening…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomiTheme.blue)
            }
            Text(
                session.askInput.isEmpty
                    ? "Say your question, then pause."
                    : session.askInput
            )
            .font(.subheadline)
            .foregroundStyle(NomiTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            session.askInput.isEmpty
                ? "Listening for your question"
                : "Hearing \(session.askInput)"
        )
    }

    private func labeled(_ speaker: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(speaker)
                .font(.caption.weight(.bold))
                .foregroundStyle(NomiTheme.blue)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(NomiTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
