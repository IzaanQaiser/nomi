import SwiftUI

/// Deterministic SwiftUI layouts for a prepared classroom slide.
struct ClassroomSlideView: View {
    let slide: ClassroomSlide
    var progressLabel: String = ""

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(NomiTheme.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(NomiTheme.hairline, lineWidth: 1)
                }
                .shadow(color: NomiTheme.ink.opacity(0.05), radius: 20, y: 8)

            VStack(alignment: .leading, spacing: 0) {
                if !progressLabel.isEmpty {
                    Text(progressLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NomiTheme.secondaryInk)
                        .padding(.bottom, 18)
                }

                layout
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layoutAlignment)
            }
            .padding(30)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle)
    }

    private var layoutAlignment: Alignment {
        switch slide.layout {
        case .checkpoint: .center
        default: .topLeading
        }
    }

    private var accessibilityTitle: String {
        slide.title.isEmpty ? "Lesson slide" : slide.title
    }

    @ViewBuilder
    private var layout: some View {
        switch slide.layout {
        case .title: titleLayout
        case .concept: conceptLayout
        case .equation: equationLayout
        case .bullets, .diagram: bulletsLayout
        case .steps: stepsLayout
        case .checkpoint: checkpointLayout
        }
    }

    private var titleLayout: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 16) {
                Text(slide.title)
                    .font(.system(size: 42, weight: .bold))
                    .tracking(-1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(NomiTheme.ink)
                    .frame(maxWidth: .infinity)
                if !slide.subtitle.isEmpty {
                    Text(slide.subtitle)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(NomiTheme.secondaryInk)
                        .frame(maxWidth: .infinity)
                }
            }
            teachingBullets
            Spacer(minLength: 0)
        }
    }

    private var conceptLayout: some View {
        VStack(alignment: .leading, spacing: 22) {
            slideHeading
            if !slide.body.isEmpty {
                Text(slide.body)
                    .font(.title3)
                    .foregroundStyle(NomiTheme.ink)
                    .lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            teachingBullets
            if !slide.callout.isEmpty {
                calloutCard(slide.callout)
            }
            Spacer(minLength: 0)
        }
    }

    private var equationLayout: some View {
        VStack(alignment: .leading, spacing: 22) {
            slideHeading
            Text(slide.equation)
                .font(.system(size: 40, weight: .medium, design: .serif))
                .foregroundStyle(NomiTheme.ink)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.45)
                .lineLimit(3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            if !slide.caption.isEmpty {
                Text(slide.caption)
                    .font(.title3)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } else if !slide.body.isEmpty {
                Text(slide.body)
                    .font(.title3)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
            teachingBullets
            Spacer(minLength: 0)
        }
    }

    private var bulletsLayout: some View {
        VStack(alignment: .leading, spacing: 20) {
            slideHeading
            if hasSupportingContent {
                HStack(alignment: .top, spacing: 28) {
                    bulletList
                        .frame(maxWidth: .infinity, alignment: .leading)
                    supportingContent
                        .frame(maxWidth: .infinity)
                }
            } else {
                bulletList
                if !slide.body.isEmpty {
                    Text(slide.body)
                        .font(.body)
                        .foregroundStyle(NomiTheme.secondaryInk)
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var stepsLayout: some View {
        VStack(alignment: .leading, spacing: 20) {
            slideHeading
            teachingBullets
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(slide.steps.enumerated()), id: \.offset, content: stepCard)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(slide.steps.enumerated()), id: \.offset, content: stepCard)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var checkpointLayout: some View {
        VStack(spacing: 18) {
            Text(slide.title.isEmpty ? "Check your understanding" : slide.title)
                .font(.subheadline.weight(.bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(NomiTheme.blue)
            Text(slide.question)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.5)
                .multilineTextAlignment(.center)
                .foregroundStyle(NomiTheme.ink)
            if !slide.body.isEmpty {
                Text(slide.body)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(NomiTheme.secondaryInk)
            }
            teachingBullets
                .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var slideHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(slide.title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(NomiTheme.ink)
            if !slide.subtitle.isEmpty {
                Text(slide.subtitle)
                    .font(.title3)
                    .foregroundStyle(NomiTheme.secondaryInk)
            }
        }
    }

    private var teachingBullets: some View {
        Group {
            if !slide.bullets.isEmpty {
                bulletList
            }
        }
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(slide.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 14) {
                    Circle()
                        .fill(NomiTheme.blue)
                        .frame(width: 8, height: 8)
                        .padding(.top, 8)
                    Text(bullet)
                        .font(.title3)
                        .foregroundStyle(NomiTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stepCard(index: Int, step: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(index + 1)")
                .font(.headline.weight(.bold))
                .foregroundStyle(NomiTheme.blue)
                .frame(width: 32, height: 32)
                .background(NomiTheme.blue.opacity(0.10), in: Circle())
            Text(step)
                .font(.body.weight(.semibold))
                .foregroundStyle(NomiTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            NomiTheme.paper,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 1)
        }
    }

    private func calloutCard(_ text: String) -> some View {
        Text(text)
            .font(.body.weight(.semibold))
            .foregroundStyle(NomiTheme.ink)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                NomiTheme.blue.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }

    private var hasSupportingContent: Bool {
        !slide.callout.isEmpty || !slide.equation.isEmpty
    }

    @ViewBuilder
    private var supportingContent: some View {
        if !slide.callout.isEmpty {
            calloutCard(slide.callout)
        } else if !slide.equation.isEmpty {
            Text(slide.equation)
                .font(.system(size: 28, weight: .medium, design: .serif))
                .foregroundStyle(NomiTheme.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
                .background(
                    NomiTheme.paper,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        } else {
            EmptyView()
        }
    }
}


private let previewNotes = [
    "A block is a system with an input and an output you can name.",
    "Arrows are signals, not wires or decoration on the page.",
    "By the end you should be able to read a closed loop out loud.",
    "The summing junction is where two signals meet and get compared.",
    "If you cannot name the output of a block, the picture is incomplete.",
    "Keep the wording from the notes instead of inventing a slogan.",
]

#Preview("Title") {
    ClassroomSlideView(
        slide: ClassroomSlide(
            layout: .title,
            title: "Block Diagrams",
            subtitle: "How signals move through a system",
            bullets: previewNotes
        ),
        progressLabel: "Slide 1 of 6"
    )
    .padding(24)
    .background(NomiTheme.paper)
}

#Preview("Concept") {
    ClassroomSlideView(
        slide: ClassroomSlide(
            layout: .concept,
            title: "What a block diagram is",
            body: "Each block is a system. Arrows are signals. The picture shows cause flowing into effect.",
            bullets: previewNotes,
            callout: "Read left to right unless a feedback path says otherwise."
        ),
        progressLabel: "Slide 2 of 6"
    )
    .padding(24)
    .background(NomiTheme.paper)
}

#Preview("Equation") {
    ClassroomSlideView(
        slide: ClassroomSlide(
            layout: .equation,
            title: "The transfer function",
            bullets: previewNotes,
            equation: "G(s) = Y(s) / U(s)",
            caption: "Output over input, in the s-domain."
        ),
        progressLabel: "Slide 3 of 6"
    )
    .padding(24)
    .background(NomiTheme.paper)
}

#Preview("Bullets") {
    ClassroomSlideView(
        slide: ClassroomSlide(
            layout: .bullets,
            title: "What to look for",
            bullets: previewNotes
        ),
        progressLabel: "Slide 4 of 6"
    )
    .padding(24)
    .background(NomiTheme.paper)
}

#Preview("Steps") {
    ClassroomSlideView(
        slide: ClassroomSlide(
            layout: .steps,
            title: "How to read the loop",
            bullets: previewNotes,
            steps: [
                "Start at the reference.",
                "Follow the plant.",
                "See what comes back.",
            ]
        ),
        progressLabel: "Slide 5 of 6"
    )
    .padding(24)
    .background(NomiTheme.paper)
}

#Preview("Checkpoint") {
    ClassroomSlideView(
        slide: ClassroomSlide(
            layout: .checkpoint,
            title: "Check your understanding",
            bullets: previewNotes,
            question: "If the output suddenly drops, what does the feedback path do?"
        ),
        progressLabel: "Slide 6 of 6"
    )
    .padding(24)
    .background(NomiTheme.paper)
}
