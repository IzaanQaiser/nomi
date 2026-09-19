import SwiftUI

/// Nomi in the top-right of the canvas. Tapping the character toggles the
/// watching tutor. Voice mute lives in the top toolbar.
struct MascotView: View {
    @ObservedObject var engine: ShadowingEngine

    private let nomiSize: CGFloat = 88

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let text = bubbleText {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: 240, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(accent.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .onTapGesture { engine.dismissHint() }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button(action: engine.toggle) {
                HStack(alignment: .center, spacing: 6) {
                    Image(poseName)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: nomiSize, height: nomiSize)
                        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                        .id(poseName)
                        .transition(.opacity)

                    if isListening {
                        AudioLevelBars()
                            .frame(width: 14, height: 34)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: poseName)
                .animation(.easeInOut(duration: 0.18), value: isListening)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shadowing tutor")
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: bubbleText)
    }

    private var isListening: Bool { if case .listening = engine.state { return true } else { return false } }

    private var poseName: String {
        switch engine.state {
        case .off: return "NomiSleep"
        case .idle: return "NomiIdle"
        case .thinking: return "NomiThinking"
        case .onTrack: return "NomiConfirm"
        case .hint: return "NomiNudge"
        case .listening: return "NomiIdle"
        case .reply: return "NomiTalk"
        }
    }

    private var bubbleText: String? {
        switch engine.state {
        case .off, .idle: return nil
        case .thinking: return nil
        case let .onTrack(note):
            if let note, !note.isEmpty { return note }
            return "Looks good so far 👍"
        case let .hint(h): return h
        case let .listening(partial):
            return partial.isEmpty ? "Listening… stay silent if you want me to jump in." : partial
        case let .reply(r): return r
        }
    }

    private var accent: Color {
        switch engine.state {
        case .off: return .gray
        case .idle, .thinking: return .blue
        case .onTrack: return .green
        case .hint: return .orange
        case .listening: return .red
        case .reply: return .blue
        }
    }
}

/// Three red capsules that bounce like a live audio meter.
private struct AudioLevelBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * (3.4 + Double(i) * 0.85) + Double(i) * 0.9
                    let level = 0.22 + 0.78 * abs(sin(phase))
                    Capsule(style: .continuous)
                        .fill(Color.red)
                        .frame(width: 3.5, height: 34 * level)
                }
            }
            .frame(height: 34, alignment: .center)
            .accessibilityHidden(true)
        }
    }
}
