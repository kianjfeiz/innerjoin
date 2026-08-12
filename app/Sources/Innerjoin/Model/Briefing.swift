import Foundation

/// What the home screen is *about*: not a list of documents, but a short list of things
/// the library noticed that a person might want to act on today.
///
/// Every card on the page is one of these, and every one is **derived** — from a date the
/// engine extracted, an anomaly Scrutiny proved, a document that just arrived. The shape
/// is deliberately uniform — why it's here, a headline, provenance, up to two things to
/// do — so the engine can grow a new kind of observation without anyone designing a new
/// card for it.
struct Signal: Identifiable, Hashable, Sendable {
    /// The *family* of observation. Drives layout weight and iconography; the wording
    /// on the card comes from the data, not from this.
    enum Kind: Hashable, Sendable {
        /// A deadline that will pass on its own if nobody acts. Gets the hero.
        case decision
        /// Something dated, coming up soon.
        case imminent
        /// Two sources that state different values for one fact — Scrutiny's work.
        case contradiction
        /// Something that arrived or changed recently.
        case arrival
        /// A person or topic the library keeps seeing.
        case topic

        /// How much room it earns. Exactly one signal may be `.hero` on a page — a
        /// screen where everything shouts is a screen with no hierarchy at all.
        var weight: Weight {
            switch self {
            case .decision:                      return .hero
            case .imminent:                      return .wide
            case .contradiction, .arrival, .topic: return .compact
            }
        }
    }

    enum Weight: Sendable { case hero, wide, compact }

    let id: UUID
    let kind: Kind
    /// The small tracked caps above the headline — "DECIDE BY WEDNESDAY", "DOESN'T
    /// MATCH". Composed from real dates and real findings, never canned.
    let eyebrow: String
    /// The headline, written as a person would say it out loud.
    let headline: String
    /// Where it came from, or when. Nil when there's nothing honest to say.
    let provenance: String?
    /// Sub-points — the other dates on the same record, say. Empty for most signals.
    let details: [String]
    let actions: [SignalAction]

    init(
        id: UUID = UUID(),
        kind: Kind,
        eyebrow: String,
        headline: String,
        provenance: String? = nil,
        details: [String] = [],
        actions: [SignalAction] = []
    ) {
        self.id = id
        self.kind = kind
        self.eyebrow = eyebrow
        self.headline = headline
        self.provenance = provenance
        self.details = details
        self.actions = actions
    }
}

/// Something the card offers to do. Every action *is a question* — the app has exactly
/// one way of doing things, the conversation, so a button press is a question asked on
/// your behalf rather than a hidden second mechanism.
struct SignalAction: Identifiable, Hashable, Sendable {
    let id: UUID
    let label: String
    /// The full question this action asks, composed against the real record — "Draft a
    /// notice to cancel Acquia MSA 2025." — so what happens on click is exactly what
    /// would happen if you typed it.
    let question: String
    /// The one action per card that gets filled emphasis. At most one, or emphasis
    /// stops meaning anything.
    let prominent: Bool

    init(id: UUID = UUID(), label: String, question: String, prominent: Bool = false) {
        self.id = id
        self.label = label
        self.question = question
        self.prominent = prominent
    }
}

/// The "34 added since yesterday" strip: what arrived, broken down by kind.
///
/// The breakdown is a list rather than named fields so a new source type — voice memos,
/// scans — needs no change here or in the view.
struct Intake: Sendable, Hashable {
    struct Slice: Identifiable, Hashable, Sendable {
        let id: UUID
        let noun: String
        let count: Int

        init(id: UUID = UUID(), noun: String, count: Int) {
            self.id = id; self.noun = noun; self.count = count
        }
    }

    let since: String
    let slices: [Slice]

    var total: Int { slices.reduce(0) { $0 + $1.count } }

    /// "12 emails · 9 documents · 7 calls · 6 sheets"
    var summary: String {
        slices.map { "\($0.count) \($0.noun)" }.joined(separator: " · ")
    }
}

/// One row in the rail. Counts appear only where something real backs them — a made-up
/// badge number is worse than none.
struct Destination: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        case home, tasks, questions, files, people, sources

        var title: String {
            switch self {
            case .home:      return "Home"
            case .tasks:     return "Tasks"
            case .questions: return "Questions"
            case .files:     return "Files"
            case .people:    return "People & topics"
            case .sources:   return "Sources"
            }
        }

        var icon: String {
            switch self {
            case .home:      return "circle.hexagongrid"
            case .tasks:     return "checkmark"
            case .questions: return "sparkle"
            case .files:     return "square.on.square"
            case .people:    return "grid"
            case .sources:   return "arrow.down.to.line"
            }
        }
    }

    var id: Kind { kind }
    let kind: Kind
    let count: Int?
}

/// A count that reads the way a person would say it: 12.8k, not 12,847.
func abbreviated(_ value: Int) -> String {
    if value >= 10_000 {
        return "\(String(format: "%.1f", Double(value) / 1000).replacingOccurrences(of: ".0", with: ""))k"
    }
    if value >= 1_000 {
        return "\(String(format: "%.1f", Double(value) / 1000))k"
    }
    return "\(value)"
}

/// The whole home screen, in one value.
struct Briefing: Sendable {
    let greeting: String
    let signals: [Signal]
    let intake: Intake
    let suggestions: [String]
    /// True when the library holds nothing at all — day one. The view shows the way in
    /// rather than an empty grid that looks broken.
    let libraryIsEmpty: Bool

    var hero: Signal? { signals.first { $0.kind.weight == .hero } }
    var wide: [Signal] { signals.filter { $0.kind.weight == .wide } }
    var compact: [Signal] { signals.filter { $0.kind.weight == .compact } }
}
