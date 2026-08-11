import Foundation
import GRDB

/// A name exactly as one document wrote it.
///
/// This is the layer innerjoin was missing, and its absence caused a specific bug: with
/// nothing between the name and the identity, the *name was* the identity, so
/// "Kian J. Feiz" and "Kian Feiz" became two people.
///
/// A mention is evidence and never changes. Which identity it belongs to is a *decision*
/// recorded on top of it, and that separation is what buys:
///
/// - **reversible merges** — merging re-points mentions, splitting points them back
/// - **non-destructive re-reading** — re-reading a document makes new mentions; the
///   identity decisions, especially a person's own corrections, survive
/// - **receipts** — every claim resolves to an anchor on a page
/// - **honest uncertainty** — `entityID` may be nil. "I don't know which Ramirez this is"
///   is a legitimate state, and far better than a confident wrong merge.
public struct Mention: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var documentID: Int64
    /// Where on the page, when the model cited it.
    public var elementTag: String?
    /// Exactly as written: "J. Ramirez".
    public var surface: String
    public var normalized: String
    public var kind: Entity.Kind
    /// The identity this was resolved to. Nil means undecided, which is allowed.
    public var entityID: Int64?
    /// Which rung of the ladder resolved it — so a wrong merge can be traced to a rule.
    public var resolvedBy: Resolution?
    public var confidence: Double

    public enum Resolution: String, Codable, CaseIterable, Sendable {
        case exact        // same normalized name
        case identifier   // shares an email or phone
        case context      // name-compatible, and co-occurs with something it knows
        case unambiguous  // name-compatible, and only one candidate in the library fits
        case user         // a person said so, and that outranks every rule
    }

    public init(id: Int64? = nil, documentID: Int64, elementTag: String? = nil,
                surface: String, kind: Entity.Kind, entityID: Int64? = nil,
                resolvedBy: Resolution? = nil, confidence: Double = 1.0) {
        self.id = id
        self.documentID = documentID
        self.elementTag = elementTag
        self.surface = surface
        self.normalized = Entity.normalize(surface)
        self.kind = kind
        self.entityID = entityID
        self.resolvedBy = resolvedBy
        self.confidence = confidence
    }
}

extension Mention: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mention"
    public enum Columns {
        public static let id = Column("id")
        public static let documentID = Column("documentID")
        public static let entityID = Column("entityID")
        public static let normalized = Column("normalized")
        public static let kind = Column("kind")
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["documentID"] = documentID
        container["elementTag"] = elementTag
        container["surface"] = surface
        container["normalized"] = normalized
        container["kind"] = kind.rawValue
        container["entityID"] = entityID
        container["resolvedBy"] = resolvedBy?.rawValue
        container["confidence"] = confidence
    }

    public init(row: Row) throws {
        id = row["id"]; documentID = row["documentID"]; elementTag = row["elementTag"]
        surface = row["surface"]; normalized = row["normalized"]
        kind = Entity.Kind(rawValue: row["kind"] ?? "") ?? .other
        entityID = row["entityID"]
        resolvedBy = (row["resolvedBy"] as String?).flatMap(Resolution.init(rawValue:))
        confidence = row["confidence"] ?? 1.0
    }
}

/// Something a document claims about someone, and when it claimed it.
///
/// The date matters more than it looks. People change jobs, move house, and renew
/// policies, so "where does Joanna work" has a *current* answer and a history. Recording
/// the **document's own** date rather than the ingest date means the current answer is
/// `ORDER BY assertedOn DESC LIMIT 1` and the history comes free. A memory that can't
/// represent change is a memory that eventually lies.
public struct Assertion: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var subjectID: Int64
    public var predicate: Predicate
    /// Set when the object is another identity — Joanna → Acme.
    public var objectEntityID: Int64?
    /// Set when the object is a plain value — a role, an email, a phone number.
    public var objectValue: String?
    public var documentID: Int64?
    public var elementTag: String?
    /// The date the *document* carries, not when we read it.
    public var assertedOn: Date?
    /// When the fact itself began and, if it has, ended. A résumé states three jobs on
    /// one page; only these tell them apart.
    public var since: Date?
    public var until: Date?

    /// Whether this is still the case as far as the document knows.
    public var isCurrent: Bool { until == nil }

    /// What to order by when deciding the current answer: the fact's own start if it
    /// has one, otherwise the date of the document that claimed it.
    public var effectiveDate: Date? { since ?? assertedOn }
    public var confidence: Double

    /// Closed, for the same reason relations are closed: left open, a model invents four
    /// spellings of "employer" and the graph stops being queryable.
    public enum Predicate: String, Codable, CaseIterable, Sendable {
        case worksAt    = "works_at"
        case role
        case email
        case phone
        case locatedIn  = "located_in"
        case relatedTo  = "related_to"
        case owns
        case memberOf   = "member_of"

        /// Whether the object is another identity rather than a plain value.
        public var takesEntity: Bool {
            switch self {
            case .worksAt, .locatedIn, .relatedTo, .owns, .memberOf: return true
            case .role, .email, .phone: return false
            }
        }

        /// Predicates that identify a person outright, and so can resolve a mention no
        /// matter how the name is spelled.
        public static let identifying: Set<Predicate> = [.email, .phone]
    }

    public init(id: Int64? = nil, subjectID: Int64, predicate: Predicate,
                objectEntityID: Int64? = nil, objectValue: String? = nil,
                documentID: Int64? = nil, elementTag: String? = nil,
                assertedOn: Date? = nil, since: Date? = nil, until: Date? = nil,
                confidence: Double = 1.0) {
        self.id = id
        self.subjectID = subjectID
        self.predicate = predicate
        self.objectEntityID = objectEntityID
        self.objectValue = objectValue
        self.documentID = documentID
        self.elementTag = elementTag
        self.assertedOn = assertedOn
        self.since = since
        self.until = until
        self.confidence = confidence
    }

    /// Identifies the claim regardless of which document made it, so the same fact stated
    /// by five documents is one row, not five.
    public var objectKey: String {
        objectEntityID.map { "entity:\($0)" } ?? (objectValue?.lowercased().trimmed ?? "")
    }
}

extension Assertion: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "assertion"
    public enum Columns {
        public static let id = Column("id")
        public static let subjectID = Column("subjectID")
        public static let predicate = Column("predicate")
        public static let assertedOn = Column("assertedOn")
        public static let documentID = Column("documentID")
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["subjectID"] = subjectID
        container["predicate"] = predicate.rawValue
        container["objectEntityID"] = objectEntityID
        container["objectValue"] = objectValue
        container["objectKey"] = objectKey
        container["documentID"] = documentID
        container["elementTag"] = elementTag
        container["assertedOn"] = assertedOn
        container["since"] = since
        container["until"] = until
        container["confidence"] = confidence
    }

    public init(row: Row) throws {
        id = row["id"]; subjectID = row["subjectID"]
        predicate = Predicate(rawValue: row["predicate"] ?? "") ?? .role
        objectEntityID = row["objectEntityID"]; objectValue = row["objectValue"]
        documentID = row["documentID"]; elementTag = row["elementTag"]
        assertedOn = row["assertedOn"]; since = row["since"]; until = row["until"]
        confidence = row["confidence"] ?? 1.0
    }
}
