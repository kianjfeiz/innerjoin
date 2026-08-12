import SwiftUI

/// "34 added since yesterday". A quiet full-width strip at the bottom of the briefing —
/// it accounts for what arrived without asking anything of you, and expands in place to
/// show the breakdown rather than sending you to another screen.
struct IntakeBar: View {
    let intake: Intake

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Theme.Motion.unfold) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.between) {
                    Text("\(intake.total)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.accentDeep)
                        .monospacedDigit()

                    Text("added \(intake.since) · \(intake.summary)")
                        .font(Theme.Font.body)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)

                    Spacer(minLength: Theme.Space.snug)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.dim)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, Theme.Space.cosy)
                .frame(height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(intake.total) items added \(intake.since)")
            .accessibilityHint(expanded ? "Collapse the breakdown" : "Expand the breakdown")

            if expanded {
                VStack(spacing: 0) {
                    Hairline()
                    VStack(spacing: 0) {
                        ForEach(Array(intake.slices.enumerated()), id: \.element.id) { index, slice in
                            IntakeRow(slice: slice, total: intake.total)
                                .arrives(index)
                        }
                    }
                    .padding(.vertical, Theme.Space.snug)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(hovering || expanded ? palette.cardHover : palette.cardQuiet)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .offset(y: hovering && !expanded && !reduceMotion ? -2 : 0)
        .animation(Theme.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct IntakeRow: View {
    let slice: Intake.Slice
    let total: Int

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.inner) {
            Text(slice.noun.capitalized)
                .font(Theme.Font.body)
                .foregroundStyle(palette.ink)
                .frame(width: 90, alignment: .leading)

            // A share bar, not a chart: it answers "which dominated?" at a glance, the
            // only question worth asking of four numbers.
            GeometryReader { geometry in
                let share = total == 0 ? 0 : Double(slice.count) / Double(total)
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.hairline.opacity(0.5))
                    Capsule()
                        .fill(palette.accent.opacity(hovering ? 0.85 : 0.55))
                        .frame(width: max(3, geometry.size.width * share))
                }
            }
            .frame(height: 4)

            Text("\(slice.count)")
                .font(Theme.Font.count)
                .foregroundStyle(palette.muted)
                .monospacedDigit()
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.cosy)
        .frame(height: 26)
        .background(hovering ? palette.accentQuiet : .clear)
        .animation(Theme.Motion.direct, value: hovering)
        .onHover { hovering = $0 }
    }
}
