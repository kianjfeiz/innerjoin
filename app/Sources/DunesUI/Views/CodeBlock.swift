import AppKit
import SwiftUI
import DunesCore

/// A reply, drawn as the things it's made of.
///
/// Prose gets inline markdown; a fenced block gets a real code block — monospaced,
/// coloured, scrolling sideways rather than wrapping, with the language named and a
/// button that puts it on the clipboard. Code that wraps at 500 points is code you have
/// to retype, and an answer you have to retype is not an answer.
struct ReplyText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Glass.Space.snug) {
            ForEach(Array(Markup.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let body):
                    Text(Self.inline(body))
                        .font(Glass.Font.body)
                        .foregroundStyle(Glass.Ink.primary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let body, _):
                    CodeBlock(language: language, code: body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown only — bold, italic, `code`, links — with whitespace preserved.
    ///
    /// `.inlineOnlyPreservingWhitespace` is the setting that matters: the full parser
    /// treats the string as a document and collapses the line breaks, which turns a
    /// deliberately broken-up answer into one paragraph. Parsing can fail outright on a
    /// half-arrived stream, so a failure falls back to the raw text rather than blanking
    /// the answer.
    private static func inline(_ markdown: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(markdown) }

        // Inline code should look like code, or `left` in a sentence reads as emphasis.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = Glass.Font.mono
            attributed[run.range].foregroundColor = Glass.Ink.primary
        }
        return attributed
    }
}

/// One fenced block.
struct CodeBlock: View {
    let language: String?
    let code: String

    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.uppercased() ?? "CODE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Glass.Ink.faint)
                Spacer(minLength: 0)
                CopyButton(copied: copied) { copy() }
                    // The button is always there for the keyboard and for VoiceOver, and
                    // fades up under the pointer — a copy button sitting at full strength
                    // on every block competes with the code for attention.
                    .opacity(hovering || copied ? 1 : 0.35)
            }
            .padding(.horizontal, Glass.Space.snug)
            .padding(.vertical, 5)

            Divider().opacity(0.25)

            // Sideways, not wrapped. Wrapping breaks indentation, and indentation is
            // load-bearing in most of what anyone pastes here.
            ScrollView(.horizontal) {
                Text(coloured)
                    .font(Glass.Font.mono)
                    .textSelection(.enabled)
                    .padding(.horizontal, Glass.Space.snug)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous)
                .strokeBorder(Glass.Fill.rim(scheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Glass.Motion.touch, value: hovering)
    }

    private var coloured: AttributedString {
        var result = AttributedString()
        for span in Markup.highlight(code, language: language) {
            var run = AttributedString(span.text)
            run.foregroundColor = Syntax.colour(span.kind, scheme)
            result.append(run)
        }
        return result
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(Glass.Motion.touch) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Glass.Motion.arrive) { copied = false }
        }
    }
}

private struct CopyButton: View {
    let copied: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .medium))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(hovering ? Glass.Ink.primary : Glass.Ink.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Glass.Motion.touch, value: hovering)
        .accessibilityLabel(copied ? "Copied" : "Copy code")
    }
}

/// Five colours, chosen to sit on glass.
///
/// Saturated editor themes assume an opaque background; over a translucent panel they
/// glow. These are muted enough to read as ink through frosted glass and still separate
/// the five kinds at a glance.
private enum Syntax {
    static func colour(_ kind: Markup.Token, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch kind {
        case .plain:   return Glass.Ink.primary
        case .keyword: return dark ? Color(red: 0.80, green: 0.62, blue: 0.95)
                                   : Color(red: 0.46, green: 0.25, blue: 0.66)
        case .string:  return dark ? Color(red: 0.56, green: 0.83, blue: 0.62)
                                   : Color(red: 0.18, green: 0.47, blue: 0.28)
        case .number:  return dark ? Color(red: 0.94, green: 0.72, blue: 0.47)
                                   : Color(red: 0.60, green: 0.36, blue: 0.10)
        case .comment: return Glass.Ink.faint
        }
    }
}
