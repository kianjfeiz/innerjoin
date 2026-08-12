import SwiftUI

/// The hero — the one filled-green card, and the only thing on the page allowed to be
/// this loud. It holds a deadline that passes on its own if nobody acts, which is the
/// one observation worth shouting about.
struct DecisionCard: View {
    let signal: Signal
    let invoke: (SignalAction) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: signal.eyebrow, onHero: true)

            Text(signal.headline)
                .font(Theme.Font.heroTitle)
                .foregroundStyle(palette.heroInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)

            if let provenance = signal.provenance {
                Text(provenance)
                    .font(Theme.Font.source)
                    .foregroundStyle(palette.heroInk.opacity(0.6))
                    .padding(.top, 5)
            }

            Spacer(minLength: 13)

            HStack(spacing: Theme.Space.snug) {
                ForEach(signal.actions) { action in
                    HeroButton(label: action.label, prominent: action.prominent) {
                        invoke(action)
                    }
                }
            }
        }
        .padding(.vertical, Theme.Space.cosy)
        .padding(.horizontal, 19)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Theme.heroGreen)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: palette.shadowHero.opacity(hovering ? 1.2 : 1),
                radius: hovering ? 18 : 14, y: hovering ? 13 : 10)
        .offset(y: hovering && !reduceMotion ? -3 : 0)
        .animation(Theme.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// The wide card beside the hero: the next dated thing, with the rest of its record's
/// dates as sub-points. "Ops Weekly in 40 minutes" is a calendar entry; this card is the
/// library adding what a calendar can't — the dates that surround the date.
struct ImminentCard: View {
    let signal: Signal
    let invoke: (SignalAction) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        FloatingCard(lift: 3) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: signal.eyebrow)

                HStack(alignment: .center, spacing: 10) {
                    Text(signal.headline)
                        .font(Theme.Font.wideTitle)
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    ForEach(signal.actions) { action in
                        ActionChip(label: action.label) { invoke(action) }
                    }
                }
                .padding(.top, Theme.Space.snug)

                if !signal.details.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(signal.details.enumerated()), id: \.offset) { _, detail in
                            HStack(alignment: .top, spacing: 9) {
                                Circle()
                                    .fill(palette.accent)
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 6)
                                Text(detail)
                                    .font(Theme.Font.body)
                                    .foregroundStyle(palette.body)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 11)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Space.cosy)
            .padding(.horizontal, 19)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        }
    }
}

/// The workhorse: one observation, its provenance, one thing to do about it. Three sit
/// in a row and they are deliberately the quietest cards on the page — if they competed
/// with the hero, the page would have no answer to "what first?".
struct SignalCard: View {
    let signal: Signal
    let invoke: (SignalAction) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        FloatingCard {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: signal.eyebrow)

                Text(signal.headline)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(palette.ink)
                    .lineSpacing(2.5)
                    // Four lines, because the headline is often a Scrutiny finding — a
                    // whole sentence naming two values — and cutting the second figure
                    // defeats the card.
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)

                Spacer(minLength: 11)

                HStack(alignment: .center, spacing: Theme.Space.snug) {
                    if let provenance = signal.provenance {
                        Text(provenance)
                            .font(Theme.Font.source)
                            .foregroundStyle(palette.faint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    ForEach(signal.actions) { action in
                        ActionChip(label: action.label) { invoke(action) }
                    }
                }
            }
            .padding(.vertical, 15)
            .padding(.horizontal, Theme.Space.cosy)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        }
    }
}
