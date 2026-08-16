import AppKit
import SwiftUI

/// A document, opened.
///
/// The panel becomes the document rather than opening a second window over it, which is
/// the same rule the rest of the app follows and the reason this doesn't need a close
/// button in the corner: Escape and the back control both lead one place.
///
/// What's shown is the markdown rendition — the text the model was actually given. That
/// matters more than it sounds: a citation checked against a prettier version of the file
/// isn't checked at all. The original is one button away for when somebody wants the real
/// thing rather than the read of it.
struct PreviewView: View {
    let preview: Library.Preview
    let back: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Glass.Space.snug) {
            HStack(spacing: Glass.Space.tight) {
                PanelButton(title: "Back", icon: "chevron.left", action: back)
                Spacer(minLength: 0)
                if let file = preview.file {
                    PanelButton(title: "Reveal", icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    PanelButton(title: "Open", icon: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(file)
                    }
                }
            }
            .arrives(0)

            Text(preview.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Glass.Ink.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .arrives(1)

            ScrollOrStack {
                Text(preview.text.isEmpty ? "This one hasn't been read yet." : preview.text)
                    .font(Glass.Font.body)
                    .foregroundStyle(preview.text.isEmpty ? Glass.Ink.tertiary : Glass.Ink.primary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Glass.Space.snug)
            }
            .background(scheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.45))
            .overlay(
                RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous)
                    .strokeBorder(Glass.Fill.rim(scheme), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous))
            .arrives(2)
        }
    }
}

// MARK: - Sources

/// The citations under an answer.
///
/// They used to be full-width rows, one per line, which made three sources look like a
/// list of results and pushed the answer off the top of a small panel. They are chips
/// now: as wide as their own name, wrapping across the panel, and each one opens the
/// document it points at. A citation you can't open is a claim with a footnote; one you
/// can is a claim you can check.
struct Sources: View {
    let citations: [Library.Citation]
    let open: (Library.Citation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Glass.Space.tight) {
            Text("FROM")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Glass.Ink.faint)

            Flow(spacing: 6, lineSpacing: 6) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                    SourceChip(citation: citation) { open(citation) }
                        .arrives(min(index, 6))
                }
            }
        }
    }
}

private struct SourceChip: View {
    let citation: Library.Citation
    let open: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Text(citation.tag)
                    .font(Glass.Font.mono)
                    .foregroundStyle(Glass.Ink.faint)
                Text(citation.document)
                    .font(Glass.Font.control)
                    .foregroundStyle(hovering ? Glass.Ink.primary : Glass.Ink.secondary)
                    .lineLimit(1)
                    // A chip is as wide as its name until the name is unreasonable, at
                    // which point it is as wide as it is allowed to be.
                    .frame(maxWidth: 220)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(hovering ? Glass.Fill.controlHover(scheme) : Glass.Fill.control(scheme))
            .overlay(Capsule().strokeBorder(Glass.Fill.rim(scheme), lineWidth: 0.5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Glass.Motion.touch, value: hovering)
        .help(citation.quote.isEmpty ? citation.document : citation.quote)
        .accessibilityLabel("Open \(citation.document), at \(citation.tag)")
    }
}

// MARK: - Laying chips out

/// Left to right, wrapping when the line runs out.
///
/// SwiftUI has no flow container, and the two obvious substitutes are both wrong here: an
/// HStack pushes chips off the edge of a 500-point panel, and a VStack turns three
/// sources into a wall. Twenty lines of `Layout` is cheaper than either compromise.
struct Flow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, limit), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + lineSpacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
