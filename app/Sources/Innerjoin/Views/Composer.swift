import SwiftUI

/// The docked composer — design D's defining move: the chat input pinned to the bottom
/// with the briefing floating above it. Suggestions sit over the field so the app always
/// offers a way in rather than presenting an empty box and waiting.
struct Composer: View {
    let suggestions: [String]
    @Binding var draft: String
    let isAnswering: Bool
    let ask: (String) -> Void

    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !suggestions.isEmpty {
                FlowLayout(spacing: 7) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        SuggestionPill(text: suggestion) { ask(suggestion) }
                            .arrives(index)
                    }
                }
            }

            HStack(spacing: Theme.Space.inner) {
                StatusMark(answering: isAnswering)

                TextField("Ask about anything you've saved…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1...5)
                    .focused($focused)
                    .accessibilityLabel("Ask a question about your library")
                    .onSubmit { submit() }

                if draft.isEmpty {
                    Text("⌘K")
                        .font(Theme.Font.mono)
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(palette.accentQuiet)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                } else {
                    SendButton(disabled: isAnswering) { submit() }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(palette.cardHover)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        focused || hovering ? palette.accent.opacity(0.7) : palette.accent.opacity(0.2),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: palette.shadowHero.opacity(focused ? 1.2 : 0.8), radius: 12, y: 8)
            .animation(Theme.Motion.hover, value: focused)
            .animation(Theme.Motion.direct, value: hovering)
            .animation(Theme.Motion.direct, value: draft.isEmpty)
            .onHover { hovering = $0 }
        }
        .background {
            Button("") { focused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        ask(question)
    }
}

/// The green square at the field's left — the app's mark, and its status. Solid when
/// ready; while an answer is forming it breathes. That pulse is the only ambient motion
/// in the app, it runs for seconds not forever, and it means something: *working*.
private struct StatusMark: View {
    let answering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Theme.heroGreen)
            .frame(width: 16, height: 16)
            .opacity(answering && breathing && !reduceMotion ? 0.45 : 1)
            .onChange(of: answering) { _, working in
                if working && !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        breathing = true
                    }
                } else {
                    withAnimation(Theme.Motion.direct) { breathing = false }
                }
            }
            .accessibilityLabel(answering ? "Working" : "Ready")
    }
}

private struct SendButton: View {
    var disabled: Bool
    var action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.heroGreen.opacity(hovering ? 1 : 0.9))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .animation(Theme.Motion.direct, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel("Ask")
    }
}

/// Wraps its children like text. `HStack` clips and `LazyVGrid` forces equal columns;
/// suggestion pills are different widths and should keep them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize.zero

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
