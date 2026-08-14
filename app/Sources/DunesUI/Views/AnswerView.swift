import SwiftUI

/// The answer, forming. The panel has grown, the question is at the top, and the
/// retrieval narrates itself before any text arrives.
struct AnswerView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Glass.Space.inner) {
                if let turn = model.turn {
                    // The question rides the same spring as the panel, up from where
                    // the field just was to the top of the answer — the one thing that
                    // visibly persists through the morph, so asking reads as the panel
                    // *becoming* the answer rather than swapping to a second screen.
                    Text(turn.question)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Glass.Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .arrives(after: 0, from: 72, on: Glass.Motion.morph)

                    if let working = turn.working {
                        WorkingNote(text: working)
                    }

                    if !turn.text.isEmpty {
                        Text(emphasised(turn.text))
                            .font(Glass.Font.body)
                            .foregroundStyle(Glass.Ink.primary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            // The answer condenses out of a blur, like focus being
                            // pulled — the glassiest thing text can do.
                            .transition(AnyTransition(.blurReplace)
                                .animation(Glass.Motion.arrive))
                    }

                    if !turn.citations.isEmpty {
                        Sources(citations: turn.citations)
                            .transition(Glass.Motion.settle(from: 4))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Glass.Space.inner)
            // The stream mutates the turn from a task, far from any withAnimation.
            // These keys put every mutation inside a transaction, so siblings reflow
            // smoothly instead of snapping to their new places around each arrival.
            .animation(Glass.Motion.arrive, value: model.turn?.working)
            .animation(Glass.Motion.arrive, value: model.turn?.text)
            .animation(Glass.Motion.arrive, value: model.turn?.citations)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: Glass.Space.snug) {
            PanelButton(title: "Ask something else", icon: "arrow.turn.up.left") {
                model.dismiss()
            }
            .arrives(after: 0.3)
        }
    }

    /// `**36**` becomes bold, and nothing else is styled. An answer full of formatting is
    /// an answer nobody trusts.
    private func emphasised(_ text: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        for piece in text.components(separatedBy: "**") {
            var run = AttributedString(piece)
            if bold { run.font = .system(size: 13, weight: .semibold) }
            result.append(run)
            bold.toggle()
        }
        return result
    }
}

/// "Reading 4 documents" — the app saying what it's doing instead of spinning.
///
/// A spinner tells someone to wait. This tells them what they're waiting for, and it
/// turns the slowest moment in the app into the most reassuring one.
private struct WorkingNote: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Glass.Ink.secondary)
                // The system's own pulse rather than a hand-rolled opacity loop: it
                // keeps its phase when the note is rewritten, so the sparkle breathes
                // through the whole wait instead of blinking awake with each step.
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text(text)
                .font(Glass.Font.control)
                .foregroundStyle(Glass.Ink.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Glass.Fill.control(scheme))
        .clipShape(Capsule())
        // One line being rewritten, not a log. Each note replaces the last, and the
        // beat of quiet between old and new is the app visibly moving to its next
        // step — it also holds the first note back until the question has landed.
        .transition(Glass.Motion.settle(after: 0.3))
        .id(text)
    }
}

/// Citations as objects you can look at, not footnote numbers. Every one resolved to a
/// real element of a real document before it got here — `Ask` drops the rest.
private struct Sources: View {
    let citations: [Library.Citation]

    var body: some View {
        VStack(alignment: .leading, spacing: Glass.Space.tight) {
            Text("FROM")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Glass.Ink.faint)

            ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                SourceChip(citation: citation).arrives(min(index, 6))
            }
        }
    }
}

private struct SourceChip: View {
    let citation: Library.Citation

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(citation.tag)
                    .font(Glass.Font.mono)
                    .foregroundStyle(Glass.Ink.tertiary)
                Text(citation.document)
                    .font(Glass.Font.control)
                    .foregroundStyle(Glass.Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            // The actual text at that anchor. A citation you can read is a citation you
            // can check without leaving the panel.
            if hovering, !citation.quote.isEmpty {
                Text(citation.quote)
                    .font(.system(size: 11))
                    .foregroundStyle(Glass.Ink.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Glass.Space.snug)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Glass.Fill.controlHover(scheme) : Glass.Fill.control(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous)
                .strokeBorder(Glass.Fill.rim(scheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous))
        .animation(Glass.Motion.arrive, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(citation.document), at \(citation.tag)")
    }
}
