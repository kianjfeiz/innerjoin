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

    /// What the hidden title bar reserves. SwiftUI adds it to whatever height the
    /// content declares, so the panel declares itself this much shorter and overflows
    /// back up into the strip — leaving the window exactly as tall as the glass, with
    /// no invisible slack hanging off either end.
    static let titlebarStrip: CGFloat = 32

    enum Radius {
        /// The window itself. Large, so the panel reads as a single soft object.
        static let panel: CGFloat = 26
        /// The frame around it. Concentric with the panel — the panel's radius plus
        /// the band between them — so the two curves nest instead of fighting.
        static let frame: CGFloat = panel + Space.band
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
        /// The thickness of the glass frame the panel sits in. Thick enough to read as
        /// a body of glass with a near and a far surface — thinner and it flattens
        /// into a stroke, which is the difference between a lens and a border.
        static let band: CGFloat = 15
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
    ///
    /// One choreography rule, everywhere: what leaves goes quickly and travels nowhere,
    /// because the panel itself is already moving and a second journey on top of the
    /// resize is how a morph turns into a wobble. What arrives comes a beat later,
    /// rising into geometry that has already settled. Exits are logistics; entrances
    /// are the show.
    enum Motion {
        /// Mode changes, where the panel morphs and resizes. A hint of bounce, because
        /// glass that stops dead reads as a cut rather than a stretch.
        static let morph = Animation.smooth(duration: 0.42, extraBounce: 0.1)
        /// Hover and press.
        static let touch = Animation.smooth(duration: 0.15)
        /// Content arriving inside a settled panel.
        static let arrive = Animation.smooth(duration: 0.3)
        /// Content leaving. A plain ease-out: an exit should be over before anyone
        /// studies it.
        static let depart = Animation.easeOut(duration: 0.14)
        /// A checkbox closing. Slower than a hover and springier than anything else in
        /// the app, because this is the one gesture that changes the library and it
        /// should be possible to watch it happen.
        static let tick = Animation.smooth(duration: 0.28, extraBounce: 0.28)
        /// A finished row leaving, and the ones below it closing the gap. Slightly
        /// longer than `arrive`: things that vanish need more time to be believed than
        /// things that appear.
        static let settleRow = Animation.smooth(duration: 0.36)
        static let stagger: Double = 0.045

        /// One branch of the panel handing off to another. The leaver fades in place
        /// and carries its own timing, so it needs nothing from the transaction; the
        /// arriving branch is `.identity` because its children stage their own
        /// entrances with `arrives`, and a container fade on top would gate their
        /// stagger behind a second curtain.
        static var handoff: AnyTransition {
            .asymmetric(insertion: .identity, removal: .opacity.animation(depart))
        }

        /// Something appearing in place, a beat after the layout around it has settled.
        /// Used for content the panel produces on its own — working notes, sources —
        /// where the pause before arrival is what makes it read as an event.
        static func settle(after delay: Double = 0, from distance: CGFloat = 6) -> AnyTransition {
            .asymmetric(
                insertion: AnyTransition.opacity.combined(with: .offset(y: distance))
                    .animation(arrive.delay(delay)),
                removal: .opacity.animation(depart)
            )
        }
    }
}

// MARK: - Drawing without a screen

/// True while the panel is being rasterised by `ImageRenderer` rather than shown.
private struct OffscreenRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var offscreenRender: Bool {
        get { self[OffscreenRenderKey.self] }
        set { self[OffscreenRenderKey.self] = newValue }
    }
}

/// A scroll view — except when the panel is being drawn offscreen.
///
/// `ImageRenderer` rasterises SwiftUI's own layers, and a `ScrollView` is backed by
/// AppKit, so it comes out empty: every offscreen render of a list is a picture of
/// nothing, which is a very convincing way to be told a list is fine when it is not.
/// Swapping it for a stack while rendering is what keeps the harness able to see rows.
struct ScrollOrStack<Content: View>: View {
    @Environment(\.offscreenRender) private var offscreen
    @ViewBuilder var content: Content

    var body: some View {
        if offscreen {
            VStack(spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        } else {
            ScrollView(.vertical) { content }
                .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - The frame

/// The band of glass the panel sits in — the app's outer edge.
///
/// It is thick glass rather than a border: a lens gathers light along its rim, goes
/// briefly dark where the surface curves away from you, and throws a sheen across the
/// shoulder it faces the light with. Those three things, layered over real Liquid
/// Glass, are what make an edge read as *depth* rather than as a drawn line.
///
/// It also gives that band something to be. Empty padding is not hit-tested and holds
/// no pixels of its own, so clicks fell through it to the desktop; a surface here
/// makes the whole frame part of the app.
struct WindowGlass: View {
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Glass.Radius.frame, style: .continuous)
    }

    var body: some View {
        Color.clear
            .glassEffect(
                .regular.tint(Glass.sand.opacity(scheme == .dark ? 0.06 : 0.10)),
                in: .rect(cornerRadius: Glass.Radius.frame, style: .continuous)
            )
            // The rim gathers light: a wide, soft band just inside the outer edge,
            // where a thick curved surface concentrates what passes through it.
            .overlay(
                shape
                    .strokeBorder(Color.white.opacity(scheme == .dark ? 0.16 : 0.32),
                                  lineWidth: 8)
                    .blur(radius: 6)
                    .allowsHitTesting(false)
            )
            // The bevel. Brightest along the top, where light falls, and lit again
            // along the bottom where it bounces back up through the glass.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(scheme == .dark ? 0.5 : 0.95), location: 0),
                            .init(color: .white.opacity(scheme == .dark ? 0.08 : 0.16), location: 0.5),
                            .init(color: .white.opacity(scheme == .dark ? 0.28 : 0.6), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            )
            // No line is drawn on the band's inner edge, and that is the whole
            // discipline here. A lens wants a far surface, and the obvious way to get
            // one is to stroke it — but the panel already draws its own edge a pixel
            // away, so any stroke here lands beside that one and the eye reads two
            // rings where there is one object. The depth comes from the gradient
            // instead: the rim glow above falls off across the band, and the panel's
            // shadow darkens its inner end. Same falloff, no second outline.
            //
            // The sheen: one soft diagonal fall across the upper shoulder. A lens has
            // a highlight, and it is never centred.
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(scheme == .dark ? 0.1 : 0.16), location: 0),
                        .init(color: .clear, location: 0.42),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .clipShape(shape)
                .allowsHitTesting(false)
            )
            .clipShape(shape)
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
    /// A number worth interrupting for. Nil means the button has nothing to say.
    var badge: String?
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
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Glass.Ink.primary)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Glass.Ink.primary.opacity(0.16)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Glass.Motion.arrive, value: badge)
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
    /// Indexed calls stagger, each next thing landing half a beat behind the last.
    func arrives(_ index: Int = 0) -> some View {
        modifier(Arrive(delay: Double(index) * Glass.Motion.stagger))
    }

    /// The same gesture, tuned: after how long, from how far, on what curve. Driven by
    /// `onAppear` rather than a transition, so it fires no matter how the view entered
    /// the hierarchy — including as a child of a branch that was swapped in whole.
    func arrives(after delay: Double, from distance: CGFloat = 6,
                 on animation: Animation = Glass.Motion.arrive) -> some View {
        modifier(Arrive(delay: delay, distance: distance, animation: animation))
    }
}

struct Arrive: ViewModifier {
    var delay: Double = 0
    var distance: CGFloat = 6
    var animation: Animation = Glass.Motion.arrive
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `ImageRenderer` never runs `onAppear`, so everything that arrives would sit at
    /// zero opacity and the render would be a picture of a panel with its content
    /// missing — which is worse than no picture, because it looks like an answer.
    @Environment(\.offscreenRender) private var offscreen

    private var visible: Bool { shown || offscreen }

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : distance)
            .onAppear {
                guard !shown else { return }
                // Reduced motion means no travel, not no grace: the offset is already
                // zeroed above, and a short fade remains — a pop is its own jolt.
                if reduceMotion {
                    withAnimation(.easeOut(duration: 0.2)) { shown = true }
                } else {
                    withAnimation(animation.delay(delay)) { shown = true }
                }
            }
    }
}
