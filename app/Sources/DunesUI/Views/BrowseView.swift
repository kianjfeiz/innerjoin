import SwiftUI

/// People, Tasks, Sources and Files — four lists, one view, because they are all the same
/// shape: a thing in your library, and the question it leads to.
///
/// Every row is tappable and every tap asks something. That's the app's one mechanism:
/// browsing is a way of finding a question, not a separate place to be.
struct BrowseView: View {
    @Bindable var model: AppModel
    let scope: Mode.Scope

    var body: some View {
        Group {
            if model.loadingRows {
                Placeholder()
            } else if model.rows.isEmpty {
                Empty(text: scope.empty)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: Glass.Space.tight) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            RowView(row: row) { model.ask(row.question) }
                                .arrives(min(index, 8))
                        }
                    }
                    .padding(.top, Glass.Space.inner)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RowView: View {
    let row: Library.Row
    let ask: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: ask) {
            HStack(spacing: Glass.Space.snug) {
                Image(systemName: row.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Glass.Ink.tertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(Glass.Font.control)
                        .foregroundStyle(Glass.Ink.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Glass.Ink.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // Appears only on hover: the row is quiet until you reach for it.
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Glass.Ink.faint)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Glass.Space.snug)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Glass.Fill.controlHover(scheme) : Glass.Fill.control(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous)
                    .strokeBorder(Glass.Fill.rim(scheme), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Glass.Motion.touch, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityHint("Ask about this")
    }
}

/// Rows at the size the real ones will be, so nothing jumps when they land.
private struct Placeholder: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(spacing: Glass.Space.tight) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous)
                    .fill(Glass.Fill.control(scheme))
                    .frame(height: 40)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Glass.Space.inner)
        .opacity(reduceMotion ? 1 : (dim ? 0.45 : 1))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityLabel("Loading")
    }
}

/// Says what's missing and what would fill it. Never just "no results".
private struct Empty: View {
    let text: String

    var body: some View {
        VStack(spacing: Glass.Space.tight) {
            Spacer()
            Text(text)
                .font(Glass.Font.body)
                .foregroundStyle(Glass.Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            Spacer()
        }
    }
}
