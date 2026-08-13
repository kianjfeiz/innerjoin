import Foundation
import GRDB

/// Notices when a document contradicts itself.
///
/// Everything else in the pipeline takes the document at its word, which is right: the
/// value stored must be the value printed, or a citation is a lie. But real paperwork is
/// full of errors — a due date before the invoice date, a total that isn't the sum of its
/// lines, "April 45", a delivery recorded before the shipment. Copying those faithfully
/// and saying nothing leaves someone to discover them the hard way.
///
/// So: **flag, never fix.** The record keeps what the document says. An anomaly sits
/// beside it saying what doesn't add up, which is what a careful person does with the
/// paper version — a sticky note, not an eraser.
///
/// Two sources, deliberately unequal. Anything a rule can decide is decided by a rule,
/// deterministically and for free. The model is asked only about what no rule can see —
/// a stated total against its own line items, a count against a list — and everything it
/// reports must still point at a real anchor before anyone sees it.
public struct Scrutiny: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    /// Dates whose order is fixed by meaning. Anything not listed is left alone: plenty
    /// of date pairs have no natural order, and inventing one produces noise.
    static let mustPrecede: [(earlier: String, later: String, why: String)] = [
        ("invoice_date", "due_date", "Payment is due before the invoice was issued"),
        ("issued", "due", "Payment is due before it was issued"),
        ("issued", "expires", "Expires before it was issued"),
        ("signed", "term_end", "The term ends before it was signed"),
        ("term_start", "term_end", "The term ends before it starts"),
        ("shipped", "delivered", "Delivered before it shipped"),
        ("order_date", "ship_by", "Shipping was due before the order was placed"),
        ("departure", "return", "The return is before the departure"),
        ("start", "end", "It ends before it starts"),
        ("statement_date", "due", "Payment is due before the statement date"),
    ]

    /// Checks one document and records what it finds. Deterministic; no model call.
    @discardableResult
    func examine(documentID: Int64, reported: [Reply.ProposedProblem] = [],
                        anchors: (String?) -> String? = { _ in nil }) async throws -> [Anomaly] {
        var found: [Anomaly] = []

        guard let record = try store.record(ofDocument: documentID), let recordID = record.id else {
            return []
        }
        let dates = try store.dates(ofRecord: recordID)
        var byKind: [String: Date] = [:]
        for date in dates where !date.derived { byKind[date.kind.lowercased()] = date.date }

        // Dates in an impossible order. The clearest kind of internal contradiction, and
        // one no amount of careful reading catches at a glance.
        for rule in Self.mustPrecede {
            guard let earlier = byKind[rule.earlier], let later = byKind[rule.later],
                  later < earlier else { continue }
            found.append(Anomaly(
                documentID: documentID, kind: .dateOrder,
                detail: "\(rule.why) — \(rule.later) \(Self.day(later)) is before \(rule.earlier) \(Self.day(earlier)).",
                foundBy: .checked))
        }

        // A date the document states that cannot exist.
        //
        // These were being lost in silence: `Dates.parse` returns nil for "April 45" and
        // the date was simply dropped, so a document with an impossible due date looked
        // identical to one with no due date at all.
        for problem in reported where problem.kind == "impossible_date" {
            found.append(Anomaly(
                documentID: documentID, kind: .impossibleDate,
                detail: problem.detail, elementTag: anchors(problem.source), foundBy: .reported))
        }

        // Everything else the reader flagged, filtered. Kept apart from the checked
        // findings by `foundBy`, because one is a proof and the other is an observation —
        // and observations need vetting.
        var seen = Set<String>()
        var reportedKept: [Anomaly] = []
        for problem in reported where problem.kind != "impossible_date" {
            // The model's own label is unreliable — measured: a misspelled "Febuary" came
            // back as `date_order`, and inconsistent casing as `count_mismatch`. The
            // sentence it wrote says plainly what the finding is, so the sentence decides
            // and the label is only a fallback. Getting this right matters because the
            // kind is what the UI groups and filters by.
            let kind = Self.classify(problem.detail)
                ?? Anomaly.Kind(rawValue: Self.normalize(problem.kind)) ?? .other
            let detail = problem.detail.trimmed
            guard detail.count >= 8, detail.count <= 300 else { continue }

            // A claim that disproves itself. Measured on a real run: "Subtotal 1855.75
            // does not match sum of line totals (450 + 749.95 + 476 + 179.8 = 1855.75)"
            // — it states the mismatch and then shows the two sides agreeing. Three of
            // four arithmetic findings on that document were this. The arithmetic is
            // right there in the sentence, so it can simply be checked.
            guard !Self.refutesItself(detail) else { continue }

            // The same observation said twice.
            let signature = Self.signature(detail)
            guard seen.insert(signature).inserted else { continue }
            reportedKept.append(Anomaly(documentID: documentID, kind: kind, detail: detail,
                                        elementTag: anchors(problem.source), foundBy: .reported))
        }

        // A document with twenty findings has none: the real ones are buried. One run
        // produced seventeen complaints that a CSV's rows weren't in date order — which
        // is not an error, rows in a file have no required order — and the genuine
        // duplicate ID sat underneath them.
        if reportedKept.count > Self.perDocumentLimit {
            reportedKept = Array(reportedKept.prefix(Self.perDocumentLimit))
        }
        found.append(contentsOf: reportedKept)

        let rows = found
        try await store.dbQueue.write { db in
            // Re-reading replaces rather than accumulating.
            try db.execute(sql: "DELETE FROM anomaly WHERE documentID = ?", arguments: [documentID])
            for var anomaly in rows { try? anomaly.insert(db) }
        }
        return rows
    }

    /// What the finding actually is, read from what was written about it.
    ///
    /// Ordered most specific first: "2025-06-31 does not exist" is an impossible date
    /// before it is anything else, and a duplicate is a duplicate even when the sentence
    /// also mentions two dates.
    public static func classify(_ detail: String) -> Anomaly.Kind? {
        let text = detail.lowercased()
        func says(_ phrases: [String]) -> Bool { phrases.contains { text.contains($0) } }

        if says(["does not exist", "doesn't exist", "not a valid date", "invalid date",
                 "is not valid", "no 31st", "has 30 days", "has 28 days",
                 "not a leap year", "month 13", "max 59", "is invalid"]) {
            return .impossibleDate
        }
        if says(["appears twice", "duplicate", "duplicated", "listed twice",
                 "same object", "appears two times"]) {
            return .duplicate
        }
        if says(["misspell", "misspelt", "typo", "spelled", "spelling"]) { return .typo }
        if says(["casing", "case", "inconsistent format", "different formats",
                 "non-iso", "format is inconsistent", "mixed format"]) {
            return .inconsistentFormat
        }
        if says(["before", "precedes", "after the event", "impossible order",
                 "reverse order", "earlier than"]) {
            return .dateOrder
        }
        if says(["does not match", "doesn't match", "but total", "= ", "sum of",
                 "should be", "adds up"]) {
            return .arithmetic
        }
        if says(["lists only", "but only", "count", "listed but"]) { return .countMismatch }
        if says(["two different", "contradict", "stated as", "conflict",
                 "but elsewhere", "inconsistent with"]) {
            return .contradiction
        }
        return nil
    }

    /// Maps what a model calls a problem onto what the schema calls one.
    static func normalize(_ kind: String) -> String {
        switch kind.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "arithmetic", "math", "total_mismatch", "sum_mismatch": return "arithmetic"
        case "count", "count_mismatch": return "countMismatch"
        case "contradiction", "inconsistency", "conflict": return "contradiction"
        case "duplicate", "duplicate_row", "duplicate_id": return "duplicate"
        case "date_order", "dateorder": return "dateOrder"
        case "impossible_date", "invalid_date": return "impossibleDate"
        case "implausible_date": return "implausibleDate"
        case "typo", "misspelling", "spelling": return "typo"
        case "inconsistent_format", "format", "formatting", "type_mismatch",
             "inconsistent_type", "unit_mismatch": return "inconsistentFormat"
        default: return "other"
        }
    }

    /// How many observations a document is allowed before the list stops being useful.
    static let perDocumentLimit = 6

    /// Whether the sentence contains the arithmetic that disproves its own claim.
    ///
    /// The pattern is always the same: "A does not match B (… = A)". If the value on the
    /// right of the last `=` already appears earlier in the sentence, the two sides the
    /// claim says differ are the same number.
    public static func refutesItself(_ detail: String) -> Bool {
        guard let equals = detail.range(of: "=", options: .backwards) else { return false }
        let left = String(detail[detail.startIndex..<equals.lowerBound])
        let right = String(detail[equals.upperBound...])
        guard let result = numbers(in: right).first else { return false }
        // Compared as written, so 1855.75 matches 1855.75 and not 1855.7.
        return numbers(in: left).contains(result)
    }

    /// Numbers as they were written, minus the punctuation that varies.
    static func numbers(in text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return [] }
        return regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            .compactMap { Range($0.range, in: cleaned).map { String(cleaned[$0]) } }
            .map { $0.contains(".") ? String(format: "%g", Double($0) ?? 0) : $0 }
    }

    /// What makes two observations the same observation, ignoring how it was worded.
    ///
    /// The figures carry the identity. "Order ID ORD-2001 appears twice" and "the sheet
    /// contains ORD-2001 twice" are one finding, and what they share is 2001 — not their
    /// verbs. Where a finding has no figures in it, the words are all there is.
    public static func signature(_ detail: String) -> String {
        let figures = numbers(in: detail).sorted()
        guard figures.isEmpty else { return figures.joined(separator: " ") }
        return detail.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
            .sorted().prefix(8).joined(separator: " ")
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
