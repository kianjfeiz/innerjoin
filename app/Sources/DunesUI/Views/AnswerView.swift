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
                        ReplyText(text: turn.text)
                            // The answer condenses out of a blur, like focus being
                            // pulled — the glassiest thing text can do.
                            .transition(AnyTransition(.blurReplace)
                                .animation(Glass.Motion.arrive))
                    }

                    if !turn.citations.isEmpty {
                        Sources(citations: turn.citations) { model.openPreview(for: $0) }
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
