import Foundation
import GRDB

/// Something in the library that is waiting on a person.
///
/// A commitment is never typed by hand. It is read out of a document — a lease that
/// ends, an invoice that falls due, a meeting a mail promises, a number that doesn't
/// add up — which is the whole difference between this list and every other task list.
/// Nothing arrives here that dunes cannot point at a sentence for.
///
/// That has one consequence worth stating plainly: the list is not owned by the person
/// who reads it. They can finish a thing, and they can decide a thing doesn't apply to
/// them, but they can't invent one, and the library will keep noticing what it notices.
public struct Commitment: Identifiable, Equatable, Sendable {

    /// What sort of attention this wants. Kept coarse on purpose: a person triaging a
    /// list is asking "is this a date I must hit, a room I must be in, or a thing I must
    /// look at?", and finer distinctions than that only slow the read.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A date that ends something, or after which an option is gone.
        case deadline
        /// A time somebody expects you to be somewhere.
        case meeting
        /// Money owed, by a date.
        case payment
        /// Someone is waiting on an answer.
        case reply
        /// A date that starts something, or that something is delivered on.
        case milestone
        /// Not a date at all: something the library found that doesn't hold up, and
        /// wants a person's eyes on.
        case check

        /// The one word that goes on the row. Anything longer competes with the title.
        public var label: String {
            switch self {
            case .deadline:  return "Deadline"
            case .meeting:   return "Meeting"
            case .payment:   return "Payment"
            case .reply:     return "Reply"
            case .milestone: return "Starts"
            case .check:     return "Check"
            }
        }

        public var symbol: String {
            switch self {
            case .deadline:  return "flag"
            case .meeting:   return "person.2"
            case .payment:   return "creditcard"
            case .reply:     return "arrowshape.turn.up.left"
            case .milestone: return "play.circle"
            case .check:     return "exclamationmark.triangle"
            }
        }

        /// How a date's own word maps onto the small set above.
        ///
        /// The model is asked for the document's vocabulary, not ours — a lease says
        /// "term end", an invoice says "due", a mail says "call". Translating here
        /// rather than constraining the prompt means a document can use a word nobody
        /// anticipated and still land somewhere sensible.
        public static func of(dateKind raw: String) -> Kind {
            let kind = raw.lowercased().replacingOccurrences(of: " ", with: "_")
            if kind.contains("meet") || kind.contains("call") || kind.contains("appointment")
                || kind.contains("interview") || kind.contains("hearing")
                || kind.contains("standup") || kind.contains("sync") { return .meeting }
            if kind.contains("pay") || kind.contains("invoice") || kind.contains("bill")
                || kind.contains("premium") || kind.contains("installment") { return .payment }
            if kind.contains("reply") || kind.contains("respond") || kind.contains("response")
                || kind.contains("follow_up") || kind.contains("followup")
                || kind.contains("rsvp") || kind.contains("confirm") { return .reply }
            if kind.contains("start") || kind.contains("begin") || kind.contains("effective")
                || kind.contains("deliver") || kind.contains("ship")
                || kind.contains("commence") || kind.contains("kickoff") { return .milestone }
            return .deadline
        }

        /// Dates that describe the past rather than ask for anything. A signature date
        /// is a fact about a document; it is not a thing to do, and putting it on a task
        /// list is how task lists become noise people stop reading.
        public static func isRecordKeeping(dateKind raw: String) -> Bool {
            let kind = raw.lowercased()
            return kind.contains("signed") || kind.contains("issued") || kind.contains("dated")
                || kind.contains("received") || kind.contains("sent")
                || kind.contains("paid") || kind.contains("closed")
                || kind.contains("completed") || kind.contains("filed")
        }
    }

    /// Stable across re-reading the document that produced it.
    ///
    /// Keyed on the document, the kind and the day — never on a row id, because
    /// understanding a document again rewrites its rows and would otherwise resurrect
    /// everything the person had already finished. Finishing something has to outlive
    /// the pipeline that found it.
    public let id: String
    public var title: String
    /// The sentence, or the shape of it, this was read out of.
    public var evidence: String?
    /// Nil for a check, which is a thing to look at rather than a date to hit.
    public var due: Date?
    public var kind: Kind
    public var documentID: Int64
    public var documentLabel: String
    /// True when dunes worked the date out rather than reading it — a notice deadline
    /// counted back from a term end. Shown, because an inferred date deserves a glance.
    public var derived: Bool
    /// Where in the document to look.
    public var elementTag: String?
    public var doneAt: Date?
    /// Set aside until this date, and invisible until then.
    public var snoozedUntil: Date?

    public var isDone: Bool { doneAt != nil }

    public init(id: String, title: String, evidence: String? = nil, due: Date? = nil,
                kind: Kind, documentID: Int64, documentLabel: String,
                derived: Bool = false, elementTag: String? = nil,
                doneAt: Date? = nil, snoozedUntil: Date? = nil) {
        self.id = id; self.title = title; self.evidence = evidence; self.due = due
        self.kind = kind; self.documentID = documentID; self.documentLabel = documentLabel
        self.derived = derived; self.elementTag = elementTag
        self.doneAt = doneAt; self.snoozedUntil = snoozedUntil
    }

    /// When it wants attention, relative to a given day.
    public enum Horizon: Int, Comparable, Sendable {
        case overdue, today, tomorrow, thisWeek, later, someday

        public static func < (a: Horizon, b: Horizon) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .overdue:  return "Overdue"
            case .today:    return "Today"
            case .tomorrow: return "Tomorrow"
            case .thisWeek: return "This week"
            case .later:    return "Later"
            case .someday:  return "No date"
            }
        }
    }

    public func horizon(now: Date = Date(), calendar: Calendar = .current) -> Horizon {
        guard let due else { return .someday }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due)
        if day < today { return .overdue }
        if day == today { return .today }
        guard let days = calendar.dateComponents([.day], from: today, to: day).day
        else { return .later }
        if days == 1 { return .tomorrow }
        return days <= 7 ? .thisWeek : .later
    }
}

// MARK: - What a person decided about it

/// The one table in the library a person writes to.
///
/// Everything else is what the documents said; this is what the reader did about it.
/// Keeping it in its own table — rather than a column on the record — is what lets a
/// document be re-read, re-understood, and rewritten without losing the fact that
/// somebody already dealt with it.
public struct TaskState: Codable, Equatable, Sendable {
    public var key: String
    public var doneAt: Date?
    public var snoozedUntil: Date?
    public var decidedAt: Date

    public init(key: String, doneAt: Date? = nil, snoozedUntil: Date? = nil,
                decidedAt: Date = Date()) {
        self.key = key; self.doneAt = doneAt
        self.snoozedUntil = snoozedUntil; self.decidedAt = decidedAt
    }
}

extension TaskState: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "taskState"
    public enum Columns {
        public static let key = Column("key")
        public static let doneAt = Column("doneAt")
        public static let snoozedUntil = Column("snoozedUntil")
    }
}
