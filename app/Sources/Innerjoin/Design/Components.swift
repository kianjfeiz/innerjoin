import SwiftUI

// MARK: - Floating card

/// Design D's elevation language: cards *float* — translucent white over the warm page,
/// a green-tinted hairline, and a soft low-alpha shadow. On hover the card rises a few
/// points, turns opaque, and the shadow deepens, so the pointer feels like it's lifting
/// a physical thing rather than triggering a style.
struct FloatingCard<Content: View>: View {
    var lift: CGFloat = 4
    var interactive = true
    @ViewBuilder var content: Content

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        content
            .background(hovering ? palette.cardHover : palette.card)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(palette.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: palette.shadowCard.opacity(hovering ? 1.4 : 1),
                    radius: hovering ? 14 : 10, y: hovering ? 10 : 7)
            .offset(y: hovering && !reduceMotion ? -lift : 0)
            .animation(Theme.Motion.hover, value: hovering)
            .onHover { hovering = interactive && $0 }
    }
}

// MARK: - Eyebrow

/// The small tracked caps above a headline. It states *why the card is here* — "DECIDE
/// BY WEDNESDAY", "DOESN'T MATCH" — so it carries information, not decoration.
struct Eyebrow: View {
    let text: String
    var onHero = false
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.eyebrow)
            .tracking(0.8)
            .foregroundStyle(onHero ? palette.heroInk.opacity(0.78) : palette.accentEyebrow)
            .lineLimit(1)
    }
}

// MARK: - Action chip

/// The small green action at a card's edge — "Prep me", "Compare". Rest: green text on
/// green-quiet. Hover: fills solid green and the text goes white, which is the mock's
/// exact behaviour and reads unambiguously as "this will do something".
struct ActionChip: View {
    let label: String
    var action: () -> Void = {}

    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.chip)
                .foregroundStyle(hovering ? Color.white : palette.accent)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(hovering ? AnyShapeStyle(Theme.heroGreen) : AnyShapeStyle(palette.accentQuiet))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .scaleEffect(pressed ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.direct, value: hovering)
        .animation(Theme.Motion.direct, value: pressed)
        .onHover { hovering = $0 }
        .pressFeedback($pressed)
    }
}

/// The two button ranks that live on the hero, where the palette inverts: a filled white
/// primary with deep-green text, and a glassy white-on-green secondary.
struct HeroButton: View {
    let label: String
    var prominent = false
    var action: () -> Void = {}

    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.action)
                .foregroundStyle(prominent ? Color(hex: 0x1D4D33) : palette.heroInk)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    prominent
                        ? Color.white.opacity(hovering ? 1 : 0.92)
                        : Color.white.opacity(hovering ? 0.26 : 0.16)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .offset(y: hovering ? -1 : 0)
                .scaleEffect(pressed ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.direct, value: hovering)
        .animation(Theme.Motion.direct, value: pressed)
        .onHover { hovering = $0 }
        .pressFeedback($pressed)
    }
}

// MARK: - Suggestion pill

/// A question the app offers to ask. Fully round so it can never be confused with the
/// squarer action chips; hover fills green and lifts, exactly as the mock has it.
struct SuggestionPill: View {
    let text: String
    var action: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? .white : palette.body)
                .padding(.horizontal, 11)
                .frame(height: 27)
                .background(hovering ? AnyShapeStyle(Theme.heroGreen) : AnyShapeStyle(palette.card))
                .overlay(
                    Capsule().strokeBorder(hovering ? Theme.heroGreen : palette.hairline, lineWidth: 1)
                )
                .clipShape(Capsule())
                .offset(y: hovering && !reduceMotion ? -2 : 0)
                .scaleEffect(pressed ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.direct, value: hovering)
        .animation(Theme.Motion.direct, value: pressed)
        .onHover { hovering = $0 }
        .pressFeedback($pressed)
    }
}

// MARK: - Hairline

/// A 1-device-pixel rule. `Divider()` picks up its own insets and colour; this doesn't.
struct Hairline: View {
    var horizontal = true
    var neutral = false
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle()
            .fill(neutral ? palette.hairlineNeutral : palette.hairline)
            .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
    }
}

// MARK: - Arrival

/// Fade and rise on first appearance — the mock's `rise` keyframe: 8pt up, staggered by
/// row. Honours reduced-motion by arriving already in place; the content is always
/// visible at the end either way.
struct Arrive: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(Theme.Motion.arrive.delay(Double(index) * Theme.Motion.stagger)) {
                        shown = true
                    }
                }
            }
    }
}

extension View {
    func arrives(_ index: Int) -> some View { modifier(Arrive(index: index)) }

    /// Scale-down on press for any button, without fighting `Button`'s own gesture.
    func pressFeedback(_ pressed: Binding<Bool>) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed.wrappedValue = true }
                .onEnded { _ in pressed.wrappedValue = false }
        )
    }
}
