import SwiftUI

/// Every colour, measurement and duration in the app, in one place — design D of the
/// mockups: a warm parchment shell, slate-blue ink, one forest-green accent, and cards
/// that float on soft shadow rather than sit behind hairlines.
///
/// Flat colour throughout — no gradients anywhere. Depth comes from layered low-alpha
/// shadows and translucency over the warm ground, never from a fade.
enum Theme {

    // MARK: - Colour

    struct Palette: Sendable {
        var shell: Color          // the outermost window fill
        var strip: Color          // the 44pt title strip
        var sidebar: Color        // the rail
        var page: Color           // the content column
        var card: Color           // floating cards (already translucent)
        var cardQuiet: Color      // the intake strip — quieter than a card
        var cardHover: Color      // a card the pointer is over
        var ink: Color            // headlines
        var body: Color           // reading text on cards, green-leaning
        var muted: Color          // secondary text
        var nav: Color            // sidebar rows at rest
        var faint: Color          // provenance, counts — warm grey
        var placeholder: Color    // the composer's resting text
        var dim: Color            // chevrons and other furniture
        var accent: Color         // forest green
        var accentDeep: Color     // the intake number, text on white-on-green buttons
        var accentEyebrow: Color  // eyebrows on light cards
        var accentQuiet: Color    // green at chip strength
        var heroInk: Color        // text on the hero
        var hairline: Color       // green-tinted card borders
        var hairlineNeutral: Color// structural rules in the shell
        var shadowCard: Color     // under floating cards
        var shadowHero: Color     // under the hero and composer
    }

    static let light = Palette(
        shell:          Color(hex: 0xFDFBF7),
        strip:          Color(hex: 0xF7F3EC),
        sidebar:        Color(hex: 0xF0ECE3),
        page:           Color(hex: 0xFAF7F0),
        card:           Color.white.opacity(0.78),
        cardQuiet:      Color.white.opacity(0.60),
        cardHover:      Color.white,
        ink:            Color(hex: 0x1B2432),
        body:           Color(hex: 0x3A4A40),
        muted:          Color(hex: 0x5D6675),
        nav:            Color(hex: 0x2C3644),
        faint:          Color(hex: 0x8B8272),
        placeholder:    Color(hex: 0x9AA1AD),
        dim:            Color(hex: 0xC3BBAA),
        accent:         Color(hex: 0x2F6B46),
        accentDeep:     Color(hex: 0x1D4D33),
        accentEyebrow:  Color(hex: 0x4A6B56),
        accentQuiet:    Color(hex: 0x2F6B46).opacity(0.10),
        heroInk:        Color(hex: 0xEFF5EC),
        hairline:       Color(hex: 0x1D3F2B).opacity(0.13),
        hairlineNeutral: Color(hex: 0x1E2837).opacity(0.09),
        shadowCard:     Color(hex: 0x18243C).opacity(0.13),
        shadowHero:     Color(hex: 0x143222).opacity(0.30)
    )

    /// Not an inversion — its own ramp on the same hues. The hero keeps the exact brand
    /// green (it reads as a filled object on either ground); everything painted *with*
    /// green lifts to sage so it stays legible on the dark warm slate.
    static let dark = Palette(
        shell:          Color(hex: 0x101316),
        strip:          Color(hex: 0x171B20),
        sidebar:        Color(hex: 0x13161B),
        page:           Color(hex: 0x15181D),
        card:           Color(hex: 0x1F242B).opacity(0.86),
        cardQuiet:      Color(hex: 0x1F242B).opacity(0.55),
        cardHover:      Color(hex: 0x262C34),
        ink:            Color(hex: 0xE9EBEE),
        body:           Color(hex: 0xB7C1B9),
        muted:          Color(hex: 0x98A1AB),
        nav:            Color(hex: 0xC6CCD4),
        faint:          Color(hex: 0x8A8478),
        placeholder:    Color(hex: 0x6E7681),
        dim:            Color(hex: 0x5A5F58),
        accent:         Color(hex: 0x6FB08A),
        accentDeep:     Color(hex: 0x9CCBAF),
        accentEyebrow:  Color(hex: 0x7FA98E),
        accentQuiet:    Color(hex: 0x6FB08A).opacity(0.14),
        heroInk:        Color(hex: 0xEFF5EC),
        hairline:       Color(hex: 0x8CBEA0).opacity(0.17),
        hairlineNeutral: Color(hex: 0xBECDDC).opacity(0.10),
        shadowCard:     Color.black.opacity(0.36),
        shadowHero:     Color.black.opacity(0.50)
    )

    /// The one colour that never moves between appearances: the hero's fill. A brand is
    /// a colour you can point at.
    static let heroGreen = Color(hex: 0x2F6B46)

    // MARK: - Space

    /// One scale. Proximity carries meaning: the gap inside a group is always visibly
    /// smaller than the gap between groups, or grouping stops reading at all.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let inner: CGFloat = 12    // inside a card
        static let cosy: CGFloat = 17     // card padding, from the mock
        static let between: CGFloat = 14  // between cards, from the mock
        static let section: CGFloat = 18  // header to first row
        static let pageH: CGFloat = 26    // content column inset
        static let pageTop: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 8
        static let chip: CGFloat = 7
        static let badge: CGFloat = 5
    }

    // MARK: - Type

    /// Hierarchy from weight and colour before size. Eyebrows are the one place
    /// letter-spacing earns its keep.
    enum Font {
        static let date = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let heroTitle = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let wideTitle = SwiftUI.Font.system(size: 15, weight: .medium)
        static let cardTitle = SwiftUI.Font.system(size: 13.5, weight: .regular)
        static let body = SwiftUI.Font.system(size: 12.5, weight: .regular)
        static let action = SwiftUI.Font.system(size: 12.5, weight: .regular)
        static let chip = SwiftUI.Font.system(size: 11.5, weight: .regular)
        static let source = SwiftUI.Font.system(size: 11.5, weight: .regular)
        static let eyebrow = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let nav = SwiftUI.Font.system(size: 13.5, weight: .regular)
        static let mono = SwiftUI.Font.system(size: 10.5, weight: .semibold, design: .monospaced)
        static let count = SwiftUI.Font.system(size: 11, weight: .regular)
    }

    // MARK: - Motion

    /// Motion is physics, not decoration. The curve is the mock's — cubic-bezier
    /// (.2,.8,.2,1), a fast start that settles without overshoot. Only `transform` and
    /// `opacity` are ever animated, so nothing reflows mid-flight.
    enum Motion {
        /// Cards arriving: rise 8pt and fade, staggered.
        static let arrive = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)
        /// Hover lift and settle.
        static let hover = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
        /// Chips, buttons, small state changes.
        static let direct = Animation.easeOut(duration: 0.18)
        /// Disclosure, where slight spring reads as physical.
        static let unfold = Animation.spring(response: 0.34, dampingFraction: 0.82)
        /// Per-card delay. Small — the mock staggers three rows across 100ms total.
        static let stagger: Double = 0.05
    }
}

extension Color {
    /// `Color(hex: 0x2F6B46)` — the palette reads as the design doc writes it.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Environment

/// The palette travels by environment so no view has to know which appearance is
/// active, and so a preview can force either one.
private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

extension EnvironmentValues {
    var palette: Theme.Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

struct PaletteProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.palette, scheme == .dark ? Theme.dark : Theme.light)
    }
}

extension View {
    func providesPalette() -> some View { modifier(PaletteProvider()) }
}
