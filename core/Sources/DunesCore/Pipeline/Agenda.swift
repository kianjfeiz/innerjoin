import Foundation

/// Everything the library is waiting on you for, in the order it wants attention.
///
/// This is a read of the library, not a store of its own. The dates and the
/// contradictions already exist because documents were understood; the agenda decides
/// which of them are *asks* rather than facts, keys them so a person's answer survives
/// the document being re-read, and puts them in the order a person actually triages in:
/// what you missed, then what is today, then the rest.
public struct Agenda: Sendable {

    /// How far back to keep looking. A deadline that slipped last month is the most
    /// important row on the screen; one from two years ago is archaeology, and a list
    /// that never forgets is a list nobody opens twice.
    public var lookBackDays: Int
    /// How far ahead to look. Long enough to catch a renewal worth acting on now.
    public var lookAheadDays: Int
    /// Whether to include things the reader set aside, and things already finished.
    public var includeSettled: Bool

    public init(lookBackDays: Int = 120, lookAheadDays: Int = 365,
                includeSettled: Bool = false) {
        self.lookBackDays = lookBackDays
        self.lookAheadDays = lookAheadDays
        self.includeSettled = includeSettled
    }

    /// Build the agenda.
    ///
    /// `now` is a parameter rather than a call to the clock so that the same library
    /// renders the same list in a test and in a screenshot.
    public func items(store: Store, now: Date = Date(),
                      calendar: Calendar = .current) throws -> [Commitment] {
        let from = calendar.date(byAdding: .day, value: -lookBackDays, to: now) ?? now
        let to = calendar.date(byAdding: .day, value: lookAheadDays, to: now) ?? now

        let documents = try store.allDocuments()
        let labels = Dictionary(
            documents.compactMap { document in document.id.map { ($0, document.label) } },
            uniquingKeysWith: { first, _ in first })
        let states = try store.taskStates()

        var items: [Commitment] = []

        // Dated asks.
        for hit in try store.dated(from: from, to: to) {
            // A signature date is a fact about a document, not a thing to do. Letting
            // those in is exactly how a task list fills with rows nobody can action and
            // stops being read.
            guard !Commitment.Kind.isRecordKeeping(dateKind: hit.date.kind) else { continue }
            let documentID = hit.record.documentID
            let key = Self.key(documentID: documentID, kind: hit.date.kind,
                               date: hit.date.date, calendar: calendar)
            items.append(Commitment(
                id: key,
                title: hit.record.title,
                evidence: hit.record.summary,
                due: hit.date.date,
                kind: .of(dateKind: hit.date.kind),
                documentID: documentID,
                documentLabel: labels[documentID] ?? "a document",
                derived: hit.date.derived,
                elementTag: hit.date.source,
                doneAt: states[key]?.doneAt,
                snoozedUntil: states[key]?.snoozedUntil))
        }

        // Things that don't add up. No date, so they sit at the end — but they are
        // genuinely actionable: somebody has to look.
        for entry in try store.flagged(limit: 100) {
            guard let documentID = entry.document.id else { continue }
            for anomaly in entry.anomalies {
                let key = Self.key(documentID: documentID, anomaly: anomaly)
                items.append(Commitment(
                    id: key,
                    title: anomaly.detail,
                    evidence: nil,
                    due: nil,
                    kind: .check,
                    documentID: documentID,
                    documentLabel: entry.document.label,
                    derived: anomaly.foundBy == .checked,
                    elementTag: anomaly.elementTag,
                    doneAt: states[key]?.doneAt,
                    snoozedUntil: states[key]?.snoozedUntil))
            }
        }

        if !includeSettled {
            items = items.filter { item in
                if item.isDone { return false }
                if let until = item.snoozedUntil, until > now { return false }
                return true
            }
        }
        return Self.ordered(items, now: now, calendar: calendar)
    }

    /// Every key the library can currently produce — what `forgetTaskStates` keeps.
    public func liveKeys(store: Store, now: Date = Date(),
                         calendar: Calendar = .current) throws -> Set<String> {
        var wide = self
        wide.includeSettled = true
        return Set(try wide.items(store: store, now: now, calendar: calendar).map(\.id))
    }

    // MARK: - Order

    /// Overdue first, then by date, then undated checks. Within a day, the kind
    /// that costs most to miss leads.
    static func ordered(_ items: [Commitment], now: Date, calendar: Calendar) -> [Commitment] {
        items.sorted { a, b in
            let ha = a.horizon(now: now, calendar: calendar)
            let hb = b.horizon(now: now, calendar: calendar)
            if ha != hb { return ha < hb }
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            default: break
            }
            if a.kind != b.kind { return weight(a.kind) < weight(b.kind) }
            return a.title < b.title
        }
    }

    private static func weight(_ kind: Commitment.Kind) -> Int {
        switch kind {
        case .payment:   return 0
        case .deadline:  return 1
        case .meeting:   return 2
        case .reply:     return 3
        case .milestone: return 4
        case .check:     return 5
        }
    }

    // MARK: - Keys

    /// Content-derived, so understanding a document again lands on the same key and a
    /// finished thing stays finished.
    public static func key(documentID: Int64, kind: String, date: Date, calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d%02d%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return "d:\(documentID):\(normalize(kind)):\(stamp)"
    }

    public static func key(documentID: Int64, anomaly: Anomaly) -> String {
        "a:\(documentID):\(anomaly.kind.rawValue):\(stableHash(anomaly.detail))"
    }

    private static func normalize(_ kind: String) -> String {
        kind.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// FNV-1a, written out rather than reached for.
    ///
    /// Swift seeds `Hasher` per process, so `hashValue` gives a different answer every
    /// launch — which would silently un-finish every checked item on restart. A key
    /// that has to survive relaunches cannot be built on a randomised hash.
    public static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}
