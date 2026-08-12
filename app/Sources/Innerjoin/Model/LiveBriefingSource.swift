import Foundation
import InnerjoinCore

/// The engine, adapted to the home screen. Every card is a query.
///
/// Nothing here is written by hand: the hero comes from a deadline `Distill` extracted
/// (or computed — notice deadlines are counted back from term ends in Swift), the
/// "doesn't match" card is an anomaly `Scrutiny` proved, the intake strip is a GROUP BY
/// over yesterday's arrivals, and the sidebar counts are the actual table counts. If the
/// library is empty the page says so, because an empty page that pretends otherwise is
/// the first lie an app tells.
final class LiveBriefingSource: BriefingSource, @unchecked Sendable {
    let workspace: URL

    init(workspace: URL) {
        self.workspace = workspace
    }

    /// The same default workspace the CLI uses, so `ijparse add` and the app are two
    /// views of one library, never two libraries.
    static var defaultWorkspace: URL {
        if let override = ProcessInfo.processInfo.environment["IJ_WORKSPACE"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: ("~/Library/Application Support/innerjoin/Personal" as NSString)
            .expandingTildeInPath)
    }

    /// One `Store` for the app's lifetime, created on first use behind a lock.
    ///
    /// Not a nicety. The briefing and the sidebar load concurrently, and when each
    /// opened its own pool the two migrators raced for the schema lock — the very first
    /// screenshot of this app was "SQLite error 5: database is locked". `Store` is built
    /// for concurrent *use* (WAL, reads beside writes); it is concurrent *opening* that
    /// has to happen exactly once.
    private let lock = NSLock()
    private var cached: Store?

    private func open() throws -> Store {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let store = try Store(root: workspace)
        cached = store
        return store
    }

    // MARK: - The briefing

    func briefing() async throws -> Briefing {
        let store = try open()
        let counts = try store.counts()

        if counts.documents == 0 {
            return Briefing(
                greeting: Self.today(),
                signals: [],
                intake: Intake(since: "so far", slices: []),
                suggestions: [],
                libraryIsEmpty: true
            )
        }

        var signals: [Signal] = []
        var suggestions: [String] = []

        // The hero: the nearest date that passes on its own if nobody acts.
        let upcoming = try store.upcoming(withinDays: 60)
        if let hero = Self.heroSignal(from: upcoming) {
            signals.append(hero)
        }
        // The next dated thing after the hero, with the rest of its record's dates as
        // sub-points — a lease shows its notice deadline beside its term end.
        if let next = Self.imminentSignal(from: upcoming, store: store,
                                          excluding: signals.first?.headline) {
            signals.append(next)
        }
        if upcoming.contains(where: { Self.decisive.contains($0.date.kind) }) {
            suggestions.append("Which deadlines are coming up?")
        }

        // What doesn't add up. `flagged` is sorted by how much is wrong with a document.
        let flagged = try store.flagged(limit: 10)
        if let contradiction = Self.contradictionSignal(from: flagged) {
            signals.append(contradiction)
            suggestions.append("What doesn't add up in my files?")
        }

        // What just arrived.
        let documents = try store.allDocuments()
        let fresh = Self.freshDocuments(documents)
        if let arrival = Self.arrivalSignal(from: fresh, store: store) {
            signals.append(arrival)
        }

        // Who keeps coming up. Hubs are entities on a large share of the library.
        let health = try store.graphHealth()
        if let topic = Self.topicSignal(from: health) {
            signals.append(topic)
            suggestions.append("What do I have about \(health.hubs[0].name)?")
        }

        let intake = Self.intake(from: fresh)
        if intake.total > 0 {
            suggestions.append("What arrived yesterday?")
        }
        if let category = try store.categoryNames().first {
            suggestions.append("What's new in \(category)?")
        }

        return Briefing(
            greeting: Self.today(),
            signals: signals,
            intake: intake,
            suggestions: Array(suggestions.prefix(4)),
            libraryIsEmpty: false
        )
    }

    func destinations() async throws -> [Destination] {
        let store = try open()
        let documents = try store.counts().documents
        let entities = try store.graphHealth().entities
        // Counts appear only where a real table backs them. Tasks, Questions and
        // Sources have no storage yet, so they get no number — a badge that's invented
        // today has to be walked back the day the feature ships.
        return [
            Destination(kind: .home, count: nil),
            Destination(kind: .tasks, count: nil),
            Destination(kind: .questions, count: nil),
            Destination(kind: .files, count: documents),
            Destination(kind: .people, count: entities),
            Destination(kind: .sources, count: nil),
        ]
    }

    // MARK: - Signals, derived

    /// Date kinds where inaction has a cost — the ones allowed to claim the hero.
    private static let decisive: Set<String> = [
        "notice_deadline", "due", "renewal", "expires", "term_end", "deadline",
    ]

    private static func heroSignal(from upcoming: [(date: RecordDate, record: Record)]) -> Signal? {
        guard let hit = upcoming.first(where: { decisive.contains($0.date.kind) }) else {
            return nil
        }
        let title = hit.record.title
        let when = dayName(hit.date.date)

        switch hit.date.kind {
        case "notice_deadline":
            return Signal(
                kind: .decision,
                eyebrow: "Decide by \(when)",
                headline: "Cancel \(title), or let it renew",
                provenance: "Notice due \(shortDate(hit.date.date))"
                    + (hit.date.derived ? " · worked out from the term" : ""),
                actions: [
                    SignalAction(label: "Draft the notice",
                                 question: "Draft a notice to cancel \(title).",
                                 prominent: true),
                    SignalAction(label: "Show the clause",
                                 question: "Show me the termination clause in \(title)."),
                ]
            )
        case "due":
            return Signal(
                kind: .decision,
                eyebrow: "Due \(when)",
                headline: amountLine(hit.record) ?? title,
                provenance: title,
                actions: [
                    SignalAction(label: "Show it",
                                 question: "What is due on \(title), and when?",
                                 prominent: true),
                ]
            )
        default: // renewal, expires, term_end, deadline
            let verb = hit.date.kind == "expires" ? "expires" : "renews"
            return Signal(
                kind: .decision,
                eyebrow: "\(verb.capitalized) \(when)",
                headline: "\(title) \(verb) on \(shortDate(hit.date.date))",
                actions: [
                    SignalAction(label: "Show the terms",
                                 question: "What are the renewal terms of \(title)?",
                                 prominent: true),
                ]
            )
        }
    }

    private static func imminentSignal(
        from upcoming: [(date: RecordDate, record: Record)],
        store: Store,
        excluding heroHeadline: String?
    ) -> Signal? {
        // The next dated record that isn't the hero's.
        guard let hit = upcoming.first(where: { pair in
            heroHeadline?.contains(pair.record.title) != true
        }) else { return nil }

        // The record's other dates become the card's sub-points — real ones, with the
        // engine's own derivations marked by their kind.
        let siblings: [String] = {
            guard let recordID = hit.record.id,
                  let dates = try? store.dates(ofRecord: recordID) else { return [] }
            return dates
                .filter { $0.id != hit.date.id }
                .prefix(2)
                .map { "\(readable($0.kind).capitalizedSentence) — \(shortDate($0.date))" }
        }()

        return Signal(
            kind: .imminent,
            eyebrow: relative(hit.date.date),
            headline: hit.record.title,
            details: siblings,
            actions: [
                SignalAction(label: "Prep me",
                             question: "Tell me everything I should know about \(hit.record.title) before \(shortDate(hit.date.date))."),
            ]
        )
    }

    private static func contradictionSignal(
        from flagged: [(document: Document, anomalies: [Anomaly])]
    ) -> Signal? {
        // The strongest finding: a contradiction proved by rule beats one the reader
        // reported, and either beats arithmetic that's merely off.
        let ranked: [Anomaly.Kind] = [.contradiction, .countMismatch, .arithmetic]
        for kind in ranked {
            for entry in flagged {
                if let anomaly = entry.anomalies.first(where: { $0.kind == kind }) {
                    return Signal(
                        kind: .contradiction,
                        eyebrow: "Doesn't match",
                        // The anomaly detail is already a plain sentence naming both
                        // values — Scrutiny's output contract — so it *is* the headline.
                        headline: anomaly.detail,
                        provenance: entry.document.label,
                        actions: [
                            SignalAction(label: "Compare",
                                         question: "What doesn't add up in \(entry.document.label)?"),
                        ]
                    )
                }
            }
        }
        return nil
    }

    private static func arrivalSignal(from fresh: [Document], store: Store) -> Signal? {
        guard let newest = fresh.first else { return nil }
        // The record's title, when the document has been understood — "Managed Hosting
        // Agreement" reads as a thing; the derived filename reads as a path.
        let name = newest.id
            .flatMap { try? store.record(ofDocument: $0)?.title }
            ?? newest.label
        let others = fresh.count - 1
        return Signal(
            kind: .arrival,
            eyebrow: "Just added",
            headline: name,
            provenance: others > 0 ? "+\(others) more" : timeOfDay(newest.addedAt),
            actions: [
                SignalAction(label: "What's in it?",
                             question: "What is \(name) about?"),
            ]
        )
    }

    private static func topicSignal(from health: Store.GraphHealth) -> Signal? {
        guard let hub = health.hubs.first else { return nil }
        return Signal(
            kind: .topic,
            eyebrow: "Keeps coming up",
            headline: "\(hub.name) appears in \(hub.records) documents",
            provenance: "\(Int(hub.share * 100))% of the library",
            actions: [
                SignalAction(label: "Show me",
                             question: "What do I have about \(hub.name)?"),
            ]
        )
    }

    // MARK: - Intake

    private static func freshDocuments(_ documents: [Document]) -> [Document] {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -36, to: now()) ?? now()
        return documents
            .filter { $0.addedAt >= cutoff }
            .sorted { $0.addedAt > $1.addedAt }
    }

    private static func intake(from fresh: [Document]) -> Intake {
        var tally: [String: Int] = [:]
        for document in fresh {
            tally[noun(for: document.typeIdentifier), default: 0] += 1
        }
        let slices = tally
            .map { Intake.Slice(noun: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        return Intake(since: "since yesterday", slices: slices)
    }

    /// UTType → the word a person would use.
    private static func noun(for typeIdentifier: String) -> String {
        let type = typeIdentifier.lowercased()
        if type.contains("email") || type.contains("eml") { return "emails" }
        if type.contains("spreadsheet") || type.contains("csv") || type.contains("numbers") { return "sheets" }
        if type.contains("audio") { return "recordings" }
        if type.contains("image") || type.contains("png") || type.contains("jpeg") { return "images" }
        if type.contains("plain-text") || type.contains("markdown") { return "notes" }
        return "documents"
    }

    // MARK: - Answering

    /// A question, narrated. The narration is real: the file count is the actual count,
    /// and the consulted list is what retrieval actually read.
    func answer(_ question: String) -> AsyncThrowingStream<AnswerChunk, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let store = try open()
                    let counts = try store.counts()
                    continuation.yield(.working("Searching \(counts.documents) file\(counts.documents == 1 ? "" : "s")"))

                    let provider = Self.providerSettings().makeProvider()
                    let ask = Ask(store: store, provider: provider)
                    let answer = try await ask.answer(question)

                    if !answer.consulted.isEmpty {
                        continuation.yield(.working("Reading \(answer.consulted.count) document\(answer.consulted.count == 1 ? "" : "s")"))
                    }

                    continuation.yield(.text(answer.text))
                    for citation in answer.citations {
                        continuation.yield(.citation(label: citation.elementTag,
                                                     document: citation.documentLabel))
                    }
                    continuation.yield(.done)
                } catch let error as ProviderError {
                    // The one failure a person can actually fix themselves gets told
                    // straight: no key, no model, and here is the command that adds one.
                    continuation.yield(.text(Self.explain(error)))
                    continuation.yield(.done)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// The environment wins (that's the harness); otherwise the provider the engine is
    /// currently tuned against. A Settings surface replaces this default, not the seam.
    private static func providerSettings() -> ProviderSettings {
        var environment = ProcessInfo.processInfo.environment
        if environment["IJ_PROVIDER"] == nil {
            environment["IJ_PROVIDER"] = "openrouter"
            environment["IJ_MODEL"] = environment["IJ_MODEL"] ?? "openai/gpt-5.6-luna"
        }
        return ProviderSettings.fromEnvironment(environment)
    }

    private static func explain(_ error: ProviderError) -> String {
        switch error {
        case .noKey:
            return "No model is connected yet, so I can search but not answer. "
                + "Add a key in Terminal with `ijparse key set openrouter`, then ask again."
        default:
            return "The model couldn't be reached: \(error.localizedDescription)"
        }
    }

    // MARK: - Words for dates

    /// The clock, or a pinned one — `IJ_TODAY=2026-08-10` — so two screenshots of the
    /// same library are byte-comparable. A harness whose output drifts on its own can't
    /// be used to review anything.
    private static func now() -> Date {
        if let pinned = ProcessInfo.processInfo.environment["IJ_TODAY"] {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            parser.locale = Locale(identifier: "en_US_POSIX")
            if let date = parser.date(from: pinned) { return date }
        }
        return Date()
    }

    private static func today() -> String {
        format(now(), as: "EEEE, MMMM d")
    }

    /// "Wednesday" inside this week, otherwise "Sep 4".
    private static func dayName(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: now(), to: date).day ?? 0
        return days < 7 ? format(date, as: "EEEE") : shortDate(date)
    }

    private static func shortDate(_ date: Date) -> String {
        format(date, as: "MMM d")
    }

    private static func timeOfDay(_ date: Date) -> String {
        format(date, as: "h:mm a").lowercased()
    }

    /// "In 3 days", "Tomorrow", "Today".
    private static func relative(_ date: Date) -> String {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: now()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case ..<1:  return "Today"
        case 1:     return "Tomorrow"
        default:    return "In \(days) days"
        }
    }

    /// "notice_deadline" → "notice deadline".
    private static func readable(_ kind: String) -> String {
        kind.replacingOccurrences(of: "_", with: " ")
    }

    private static func amountLine(_ record: Record) -> String? {
        guard let amount = record.amount else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = record.currency ?? "USD"
        formatter.maximumFractionDigits = amount.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        let money = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return "\(money) — \(record.title)"
    }

    private static func format(_ date: Date, as pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

extension String {
    /// "notice deadline" → "Notice deadline". `capitalized` would title-case every word.
    var capitalizedSentence: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
