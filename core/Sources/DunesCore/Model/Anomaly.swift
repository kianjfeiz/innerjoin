import Foundation
import GRDB

/// Something wrong with a document, noticed while reading it.
///
/// Not something wrong with *our* reading — that's `Document.problem`. This is the
/// document contradicting itself: a due date before the invoice date, a total that isn't
/// the sum of its lines, "ITEMS: 3" above four items, a date of April 45.
///
/// The rule is **flag, never fix**. The stored value stays exactly what the document
/// says, because the moment dunes silently corrects a figure it becomes a thing that
/// invents numbers, and every citation stops meaning what it appears to mean. An anomaly
/// sits beside the value and says "this doesn't add up", which is what a careful person
/// would do with the paper version.
public struct Anomaly: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var documentID: Int64
    public var kind: Kind
    /// Plain language, shown to a person: "Due 2025-04-01 is before the invoice date."
    public var detail: String
    /// Where to look, when we know.
    public var elementTag: String?
    /// Whether dunes worked this out itself or the model reported it.
    public var foundBy: Source
    public var noticedAt: Date

    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A date the document states that isn't a real date — April 45, February 31.
        case impossibleDate
        /// A date that parses but can't be true — a lease ending in 1804.
        case implausibleDate
        /// Two dates in the wrong order: delivered before shipped, return before outbound.
        case dateOrder
        /// Arithmetic the document states that doesn't hold.
        case arithmetic
        /// A stated count that doesn't match what's listed.
        case countMismatch
        /// The document says two different things about one fact.
        case contradiction
        /// Something repeated that shouldn't be — a duplicate row or identifier.
        case duplicate
        /// A misspelling in something that matters — a month name, a company, a domain.
        case typo
        /// One fact written two ways: kWh and kwh, "West" and "west", two date formats.
        case inconsistentFormat
        /// Anything else the reader flagged.
        case other
    }

    public enum Source: String, Codable, Sendable {
        /// Worked out in Swift from what was extracted. Deterministic and free.
        case checked
        /// Reported by the model while reading. Cheaper than any rule for the open-ended
        /// cases, and never trusted for anything a rule can decide.
        case reported
    }

    public init(id: Int64? = nil, documentID: Int64, kind: Kind, detail: String,
                elementTag: String? = nil, foundBy: Source = .checked,
                noticedAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.kind = kind
        self.detail = detail
        self.elementTag = elementTag
        self.foundBy = foundBy
        self.noticedAt = noticedAt
    }
}

extension Anomaly: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "anomaly"
    public enum Columns {
        public static let id = Column("id")
        public static let documentID = Column("documentID")
        public static let kind = Column("kind")
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["documentID"] = documentID
        container["kind"] = kind.rawValue
        container["detail"] = detail
        container["elementTag"] = elementTag
        container["foundBy"] = foundBy.rawValue
        container["noticedAt"] = noticedAt
    }

    public init(row: Row) throws {
        id = row["id"]; documentID = row["documentID"]
        kind = Kind(rawValue: row["kind"] ?? "") ?? .other
        detail = row["detail"]; elementTag = row["elementTag"]
        foundBy = Source(rawValue: row["foundBy"] ?? "") ?? .checked
        noticedAt = row["noticedAt"] ?? Date()
    }
}
