import SwiftUI

/// Compact right-rail Q&A for Ask Nomi. The slide stays the visual focus.
struct ClassroomAskCard: View {
    @Bindable var session: ClassroomSession
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if session.visibleExchanges.isEmpty, !session.isSendingAsk {
                        Text("Ask about this slide")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NomiTheme.secondaryInk)
                    }

                    ForEach(session.visibleExchanges) { turn in
                        VStack(alignment: .leading, spacing: 6) {
                            labeled("You", turn.question)
                            labeled("Nomi", turn.answer)
                        }
                    }

                    if session.isSendingAsk {
                        HStack(spacing: 8) {
                            ProgressView().tint(NomiTheme.blue)
                            Text("Thinking…")
                                .font(.subheadline)
                                .foregroundStyle(NomiTheme.secondaryInk)
                        }
                    }

                    if let askError = session.askError {
                        Text(askError)
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                        if !session.askInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Try again") {
                                Task { await session.sendAsk() }
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(NomiTheme.blue)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                TextField(
                    session.isListening ? "Listening…" : "Ask Nomi…",
                    text: $session.askInput,
                    axis: .vertical
                )
                .font(.subheadline)
                .foregroundStyle(NomiTheme.ink)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .focused($inputFocused)
                .lineLimit(1...3)
                .disabled(session.isSendingAsk || session.isListening)
                .onSubmit {
                    Task { await session.sendAsk() }
                }
                .onChange(of: session.askInput) { _, value in
                    if value.count > 2000 { session.askInput = String(value.prefix(2000)) }
                }

                Button {
                    Task { await session.toggleListening() }
                } label: {
                    Image(systemName: session.isListening ? "mic.fill" : "mic")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(session.isListening ? Color.white : NomiTheme.blue)
                        .frame(width: 34, height: 34)
                        .background(
                            session.isListening ? NomiTheme.blue : NomiTheme.blue.opacity(0.10),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(session.isSendingAsk)
                .accessibilityLabel(session.isListening ? "Stop listening" : "Ask with voice")

                Button {
                    Task { await session.sendAsk() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            canSend ? NomiTheme.blue : NomiTheme.blueMuted,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send question")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(NomiTheme.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(NomiTheme.hairline, lineWidth: 1)
            }

            Button("Continue lesson") {
                inputFocused = false
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
    }

    private var canSend: Bool {
        !session.askInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.isSendingAsk
            && !session.isListening
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
