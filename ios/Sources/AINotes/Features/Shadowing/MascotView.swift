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
                    ZStack {
                        // Keying by pose cross-dissolves the expression while the
                        // (identical) blue body stays put, so an emotion change
                        // reads as Nomi morphing rather than a hard image swap.
                        NomiView(pose: pose)
                            .frame(width: nomiSize, height: nomiSize)
                            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                            .id(pose)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)),
                                removal: .opacity
                            ))
                    }

                    if isListening {
                        AudioLevelBars()
                            .frame(width: 14, height: 34)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: pose)
                .animation(.easeInOut(duration: 0.18), value: isListening)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shadowing tutor")
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: bubbleText)
    }

    private var isListening: Bool { if case .listening = engine.state { return true } else { return false } }

    /// Maps the live tutor state onto a pose for the vector Nomi rig.
    private var pose: NomiPose {
        switch engine.state {
        case .off: return .sleep
        case .idle: return .idle
        case .thinking: return .thinking
        case .onTrack: return .confirm
        case .hint: return .nudge
        case .listening: return .listening
        case .reply: return .talk
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

extension NomiPose {
    /// Bridges the old PNG asset names to a live pose so every screen that used
    /// `Image("NomiX")` can drop in a `NomiView` instead.
    init(assetName: String) {
        switch assetName {
        case "NomiSleep":    self = .sleep
        case "NomiThinking": self = .thinking
        case "NomiConfirm":  self = .confirm
        case "NomiNudge":    self = .nudge
        case "NomiTalk":     self = .talk
        default:             self = .idle   // NomiIdle
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
