import SwiftUI

/// The conversation, once one has started. It replaces the briefing in place rather
/// than pushing a new screen — one window, one place things happen.
struct Conversation: View {
    let exchanges: [Exchange]
    let clear: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            BackRow(action: clear)

            ForEach(exchanges) { exchange in
                ExchangeView(exchange: exchange)
                    .id(exchange.id)
            }
        }
    }
}

private struct BackRow: View {
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                Text("Back to today")
                    .font(.system(size: 12))
            }
            .foregroundStyle(hovering ? palette.ink : palette.muted)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(hovering ? palette.card : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.direct, value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct ExchangeView: View {
    let exchange: Exchange
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.inner) {
            Text(exchange.question)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let working = exchange.working {
                WorkingNote(text: working)
            }

            if !exchange.answer.isEmpty {
                // A figure that matters is bold; nothing else is styled. An answer full
                // of formatting is an answer nobody trusts.
                Text(emphasised(exchange.answer))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
                    .transition(.opacity)
            }

            if !exchange.citations.isEmpty {
                CitationRow(citations: exchange.citations)
            }
        }
        .animation(Theme.Motion.hover, value: exchange.answer.isEmpty)
    }

    /// Turns `**36**` into bold without pulling in a markdown renderer.
    private func emphasised(_ text: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        for piece in text.components(separatedBy: "**") {
            var run = AttributedString(piece)
            if bold {
                run.font = .system(size: 14, weight: .semibold)
            }
            result.append(run)
            bold.toggle()
        }
        return result
    }
}

/// "Reading 4 documents" — the app narrating its own retrieval. This exists instead of
/// a spinner: a spinner says wait, this says what is being waited for.
private struct WorkingNote: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(palette.accentQuiet)
        .clipShape(Capsule())
        // Each note replaces the last — one line being rewritten, not a list growing.
        .transition(.opacity.combined(with: .offset(y: 4)))
        .id(text)
    }
}

/// Citations as first-class objects: a chip that opens the source, not a footnote.
private struct CitationRow: View {
    let citations: [Exchange.Citation]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Eyebrow(text: "From")
            FlowLayout(spacing: Theme.Space.snug) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                    CitationChip(citation: citation).arrives(index)
                }
            }
        }
    }
}

private struct CitationChip: View {
    let citation: Exchange.Citation

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button {} label: {
            HStack(spacing: 6) {
                Text(citation.label)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.accent)
                Text(citation.document)
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? palette.ink : palette.muted)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.faint)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(hovering ? palette.cardHover : palette.card)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(hovering ? palette.accent.opacity(0.4) : palette.hairline,
                                  lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.direct, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel("Open \(citation.document) at \(citation.label)")
    }
}
