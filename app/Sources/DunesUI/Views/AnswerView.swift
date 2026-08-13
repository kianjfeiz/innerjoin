import SwiftUI

/// The answer, forming. The panel has grown, the question is at the top, and the
/// retrieval narrates itself before any text arrives.
struct AnswerView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Glass.Space.inner) {
                if let turn = model.turn {
                    Text(turn.question)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Glass.Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)

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
                    }

                    if !turn.citations.isEmpty {
                        Sources(citations: turn.citations)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Glass.Space.inner)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: Glass.Space.snug) {
            PanelButton(title: "Ask something else", icon: "arrow.turn.up.left") {
                model.dismiss()
            }
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
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Glass.Ink.secondary)
                .opacity(breathing && !reduceMotion ? 0.35 : 1)
            Text(text)
                .font(Glass.Font.control)
                .foregroundStyle(Glass.Ink.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Glass.Fill.control(scheme))
        .clipShape(Capsule())
        // Replaces the previous note rather than stacking — one line being rewritten.
        .transition(.opacity.combined(with: .offset(y: 4)))
        .id(text)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
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
                SourceChip(citation: citation).arrives(index)
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
