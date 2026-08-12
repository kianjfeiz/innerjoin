import SwiftUI

/// The home screen: today's date, the derived briefing, what came in, and the way to
/// ask. Design D's rhythm — a wide hero beside a narrower dated card (1.25 : 1), then a
/// row of three quiet cards, then a full-width strip. Three shapes in one column; a page
/// where every row matches reads as generated no matter how good the cards are.
struct HomeView: View {
    let briefing: Briefing
    let model: AppModel

    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if model.exchanges.isEmpty {
                    briefingBody
                } else {
                    Conversation(exchanges: model.exchanges) {
                        withAnimation(Theme.Motion.hover) { model.clearConversation() }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.pageH)
            .padding(.top, Theme.Space.pageTop)
            .padding(.bottom, Theme.Space.between)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var briefingBody: some View {
        Text(briefing.greeting)
            .font(Theme.Font.date)
            .foregroundStyle(palette.ink)
            .arrives(0)

        if briefing.libraryIsEmpty {
            EmptyLibrary()
                .padding(.top, Theme.Space.section)
                .arrives(1)
        } else {
            // Hero row: the decision beside the next dated thing. The mock's ratio is
            // 1.25 : 1; the side card takes a fixed width and the hero absorbs the rest,
            // because two flexible widths plus layout priority starves the smaller one —
            // the first screenshot rendered its text one letter per line.
            HStack(alignment: .top, spacing: Theme.Space.between) {
                if let hero = briefing.hero {
                    DecisionCard(signal: hero) { model.invoke($0) }
                        .frame(maxWidth: .infinity)
                        .arrives(1)
                }
                ForEach(Array(briefing.wide.enumerated()), id: \.element.id) { index, signal in
                    ImminentCard(signal: signal) { model.invoke($0) }
                        .frame(width: 330)
                        .arrives(2 + index)
                }
            }
            .padding(.top, Theme.Space.section)

            if !briefing.compact.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 214), spacing: Theme.Space.between)],
                    alignment: .leading,
                    spacing: Theme.Space.between
                ) {
                    ForEach(Array(briefing.compact.enumerated()), id: \.element.id) { index, signal in
                        SignalCard(signal: signal) { model.invoke($0) }
                            .arrives(3 + index)
                    }
                }
                .padding(.top, Theme.Space.between)
            }

        }
    }
}

/// Day one. The empty state is the first screen anyone sees, so it says exactly what to
/// do rather than showing a grid with nothing in it.
private struct EmptyLibrary: View {
    @Environment(\.palette) private var palette

    var body: some View {
        FloatingCard(interactive: false) {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Eyebrow(text: "Empty library")
                Text("Nothing saved yet")
                    .font(Theme.Font.heroTitle)
                    .foregroundStyle(palette.ink)
                Text("Add files from Terminal — `ijparse add ~/Documents` reads a folder — "
                     + "and this page will start noticing deadlines, contradictions and "
                     + "people worth knowing about. Originals are copied, never moved.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480, alignment: .leading)
            }
            .padding(Theme.Space.cosy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
