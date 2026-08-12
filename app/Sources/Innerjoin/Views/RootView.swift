import SwiftUI

/// The window: the title strip across the whole top, the rail on the left, content on
/// the right, composer docked at the bottom. Hand-built rather than
/// `NavigationSplitView` because design D puts the traffic lights in a full-width strip
/// and pins the composer under a scrolling region — both mean fighting that container.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var query = ""

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip()

            HStack(spacing: 0) {
                Sidebar(
                    destinations: model.destinations,
                    selection: $model.selected,
                    query: $query
                )

                content
                    .frame(maxWidth: .infinity)
                    .background(palette.page)
            }
        }
        .background(palette.shell)
        .frame(minWidth: 880, minHeight: 580)
        // One stacking context for the window, so nothing inside needs a z-index war.
        .compositingGroup()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingState()
        case .failed(let reason):
            FailedState(reason: reason) { Task { await model.load() } }
        case .ready:
            if let briefing = model.briefing {
                VStack(spacing: 0) {
                    if model.selected == .home {
                        HomeView(briefing: briefing, model: model)
                    } else {
                        ComingSoonState(destination: model.selected)
                    }

                    // Pinned above the composer, not floating after the cards — the
                    // mock's `margin-top: auto`. What arrived belongs with the way in.
                    if model.selected == .home, model.exchanges.isEmpty,
                       briefing.intake.total > 0 {
                        IntakeBar(intake: briefing.intake)
                            .padding(.horizontal, Theme.Space.pageH)
                            .padding(.bottom, 4)
                            .frame(maxWidth: 980, alignment: .leading)
                            .arrives(6)
                    }

                    Composer(
                        suggestions: model.exchanges.isEmpty && model.selected == .home
                            ? briefing.suggestions : [],
                        draft: $model.draft,
                        isAnswering: model.isAnswering
                    ) { model.ask($0) }
                    .padding(.horizontal, Theme.Space.pageH)
                    .padding(.bottom, 20)
                    .padding(.top, 6)
                    .frame(maxWidth: 980, alignment: .leading)
                }
            } else {
                LoadingState()
            }
        }
    }
}

// MARK: - States

/// Skeleton shapes at the sizes the real cards will be, so the layout doesn't jump when
/// content lands. A centred spinner would tell the user nothing about what's coming.
private struct LoadingState: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            block(width: 210, height: 26)
            HStack(alignment: .top, spacing: Theme.Space.between) {
                block(height: 150).layoutPriority(1.25)
                block(height: 150)
            }
            HStack(spacing: Theme.Space.between) {
                ForEach(0..<3, id: \.self) { _ in block(height: 112) }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.pageH)
        .padding(.top, Theme.Space.pageTop)
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
        .opacity(reduceMotion ? 1 : (shimmer ? 1 : 0.55))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .accessibilityLabel("Loading today's briefing")
    }

    private func block(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(palette.card.opacity(0.5))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
    }
}

/// Says what went wrong and offers the one thing that might fix it. No apology, no
/// exclamation mark, no dead end.
private struct FailedState: View {
    let reason: String
    let retry: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.inner) {
            Eyebrow(text: "Couldn't open the library")
            Text(reason)
                .font(.system(size: 14))
                .foregroundStyle(palette.ink)
                .lineSpacing(3)
                .frame(maxWidth: 460, alignment: .leading)
            ActionChip(label: "Try again", action: retry)
                .padding(.top, Theme.Space.tight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// The other destinations, honest about not existing yet rather than showing an empty
/// list that looks broken.
private struct ComingSoonState: View {
    let destination: Destination.Kind
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: Theme.Space.snug) {
            Image(systemName: destination.icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(palette.dim)
            Text(destination.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.ink)
            Text("Not built yet. Ask below — the answer draws on everything here.")
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
