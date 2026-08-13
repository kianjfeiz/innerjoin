import SwiftUI

/// The whole visual language, in one file.
///
/// The surface is Liquid Glass — real `glassEffect`, not a blur imitating one — so the
/// panel samples and refracts whatever is behind the window. That means the app supplies
/// almost no colour of its own: the desktop provides it. What's defined here is the
/// geometry, the type, and the few restrained fills that sit *on* the glass.
enum Glass {

    // MARK: - Geometry

    /// The panel at rest. Small on purpose — this is a thing you ask, not a thing you
    /// browse. It grows only when it has something to show.
    static let restSize = CGSize(width: 560, height: 340)
    static let openSize = CGSize(width: 560, height: 520)

    enum Radius {
        /// The window itself. Large, so the panel reads as a single soft object.
        static let panel: CGFloat = 26
        static let field: CGFloat = 14
        static let control: CGFloat = 10
        static let pill: CGFloat = 999
    }

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 6
        static let snug: CGFloat = 10
        static let inner: CGFloat = 14
        static let edge: CGFloat = 22
        static let gap: CGFloat = 18
    }

    // MARK: - Type

    /// Four sizes. Hierarchy comes from weight and opacity before it comes from size,
    /// which is what lets a panel this small stay calm.
    enum Font {
        static let wordmark = SwiftUI.Font.system(size: 19, weight: .bold)
        static let prompt = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let field = SwiftUI.Font.system(size: 14, weight: .regular)
        static let control = SwiftUI.Font.system(size: 12.5, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let footnote = SwiftUI.Font.system(size: 10.5, weight: .regular)
        static let mono = SwiftUI.Font.system(size: 10.5, weight: .medium, design: .monospaced)
    }

    // MARK: - Ink

    /// Text only ever uses the system's own semantic colours, because glass changes what
    /// is behind it from moment to moment and only the system's adaptive ink stays
    /// legible against a desktop it cannot predict.
    enum Ink {
        static let primary = Color.primary
        static let secondary = Color.secondary
        static let tertiary = Color.primary.opacity(0.45)
        static let faint = Color.primary.opacity(0.3)
    }

    /// A whisper of warmth, so the panel nods at its own name without becoming a colour
    /// scheme. Applied to the glass as a tint, which modulates the material rather than
    /// painting over it — at this strength it reads as light through sand, not as brown.
    static let sand = Color(red: 0.83, green: 0.72, blue: 0.55)

    // MARK: - Surfaces that sit *on* the glass

    /// Liquid Glass cannot sample other Liquid Glass — Apple is explicit about it, and a
    /// nested pane comes out flat and wrong. So the panel is the single glass surface,
    /// and everything inside it is drawn with these plain translucent fills instead.
    /// They read as frosted because of what they sit on, not because of what they are.
    enum Fill {
        /// The ask field: the one place text has to be read at length, so it's the most
        /// opaque thing on the panel.
        static func field(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.62)
        }
        /// Buttons and chips at rest.
        static func control(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.42)
        }
        /// The same, under the pointer.
        static func controlHover(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.15) : Color.white.opacity(0.72)
        }
        /// The hairline that gives a fill its edge. Light from above, as glass implies.
        static func rim(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.55)
        }
    }

    // MARK: - Motion

    /// Liquid Glass has its own physics — shapes stretch toward each other and settle.
    /// These curves are chosen to agree with it: nothing linear, nothing that overshoots
    /// hard enough to wobble.
    enum Motion {
        /// Mode changes, where the panel morphs and resizes.
        static let morph = Animation.smooth(duration: 0.38, extraBounce: 0.08)
        /// Hover and press.
        static let touch = Animation.smooth(duration: 0.16)
        /// Content arriving inside a settled panel.
        static let arrive = Animation.smooth(duration: 0.26)
        static let stagger: Double = 0.04
    }
}

// MARK: - Controls

/// A rounded control drawn on the glass: the scope buttons, `Files`, chips.
///
/// Every state is designed — rest, hover, pressed, disabled — because a launcher is
/// almost entirely controls, and the ones that don't respond are the ones that make an
/// app feel dead.
struct GlassControl: ViewModifier {
    var radius: CGFloat = Glass.Radius.control
    var hovering: Bool
    var pressed: Bool

    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(hovering ? Glass.Fill.controlHover(scheme) : Glass.Fill.control(scheme))
            .overlay(shape.stroke(Glass.Fill.rim(scheme), lineWidth: 0.5))
            .clipShape(shape)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(Glass.Motion.touch, value: hovering)
            .animation(Glass.Motion.touch, value: pressed)
    }
}

/// A button with the panel's look. Used for every tappable thing except the send key.
struct PanelButton: View {
    let title: String
    var icon: String?
    var wide = false
    var action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title).font(Glass.Font.control)
            }
            .foregroundStyle(hovering ? Glass.Ink.primary : Glass.Ink.secondary)
            .padding(.horizontal, wide ? 0 : 12)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: 30)
            .modifier(GlassControl(hovering: hovering, pressed: pressed))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

extension View {
    /// Fade and rise, once. 6pt — enough to read as arriving, not enough to look thrown.
    func arrives(_ index: Int = 0) -> some View { modifier(Arrive(index: index)) }
}

struct Arrive: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true } else {
                    withAnimation(Glass.Motion.arrive.delay(Double(index) * Glass.Motion.stagger)) {
                        shown = true
                    }
                }
            }
    }
}
