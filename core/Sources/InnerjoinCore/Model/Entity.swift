import Foundation
import GRDB

/// A person, organization, or place that shows up across documents.
///
/// Entities are what make the knowledge graph a graph: the same landlord appearing on
/// a lease, an email, and a payment is one node with three edges, not three strings.
public struct Entity: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    /// The form we show — usually the first one seen.
    public var name: String
    /// Lowercased, de-punctuated, suffix-stripped. The matching key.
    public var normName: String
    public var kind: Kind
    /// Other surface forms that resolved to this entity ("Alcon Laboratories, Inc.").
    public var aliases: [String]
    public var createdAt: Date
    /// The dates of the earliest and latest documents this identity appears in — its own
    /// dates, not when we read them. "Known since March 2024" is a fact about the person.
    public var firstSeenOn: Date?
    public var lastSeenOn: Date?
    /// The user. Still kept out of clustering, but present so relationships have a
    /// second end: "my landlord" needs a "my".
    public var isOwner: Bool
    /// A name the user chose. Re-reading may add aliases but must never overwrite this.
    public var pinnedName: String?

    /// What to show: the user's choice if they made one, otherwise the best form seen.
    public var label: String { pinnedName ?? name }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        // `project` earns its place beside the others: a body of work recurs across
        // documents and accumulates facts exactly as a person or a company does, and
        // filing it under `other` made it unrepresentable — `other` can never be a
        // document's party.
        case person, org, place, project, product, account, other
    }

    public init(id: Int64? = nil, name: String, kind: Kind,
                aliases: [String] = [], createdAt: Date = Date(),
                firstSeenOn: Date? = nil, lastSeenOn: Date? = nil,
                isOwner: Bool = false, pinnedName: String? = nil) {
        self.id = id
        self.name = name
        self.normName = Entity.normalize(name)
        self.kind = kind
        self.aliases = aliases
        self.createdAt = createdAt
        self.firstSeenOn = firstSeenOn
        self.lastSeenOn = lastSeenOn
        self.isOwner = isOwner
        self.pinnedName = pinnedName
    }

    /// Cheap, deterministic normalization — the first rung of the resolution ladder.
    /// Fuzzy matching and model adjudication come later; most names match right here.
    public static func normalize(_ name: String) -> String {
        var text = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        for suffix in [" inc", " inc.", " llc", " l.l.c.", " ltd", " ltd.", " co", " co.",
                       " corp", " corp.", " corporation", " company", " gmbh", " plc"] {
            if text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        }
        text = text.replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: "",
                                         options: .regularExpression)
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
    }
}

extension Entity: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "entity"
    public enum Columns {
        public static let id = Column("id")
        public static let normName = Column("normName")
        public static let kind = Column("kind")
        public static let name = Column("name")
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["normName"] = normName
        container["kind"] = kind.rawValue
        container["createdAt"] = createdAt
        container["firstSeenOn"] = firstSeenOn
        container["lastSeenOn"] = lastSeenOn
        container["isOwner"] = isOwner
        container["pinnedName"] = pinnedName
        container["aliases"] = String(data: try JSONEncoder().encode(aliases), encoding: .utf8)
    }

    public init(row: Row) throws {
        id = row["id"]; name = row["name"]; normName = row["normName"]
        kind = Kind(rawValue: row["kind"]) ?? .other
        createdAt = row["createdAt"]
        firstSeenOn = row["firstSeenOn"]; lastSeenOn = row["lastSeenOn"]
        isOwner = row["isOwner"] ?? false; pinnedName = row["pinnedName"]
        if let json: String = row["aliases"], let data = json.data(using: .utf8) {
            aliases = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else { aliases = [] }
    }
}

/// One edge of the graph. Endpoints are typed strings — "record:42", "entity:7" — so
/// a single table can hold record↔entity and record↔record without a join per kind.
public struct Link: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var src: String
    public var rel: String
    public var dst: String
    public var confidence: Double
    /// Which document asserted this, so an edge can be traced back.
    public var documentID: Int64?

    public init(id: Int64? = nil, src: String, rel: String, dst: String,
                confidence: Double = 1.0, documentID: Int64? = nil) {
        self.id = id; self.src = src; self.rel = rel; self.dst = dst
        self.confidence = confidence; self.documentID = documentID
    }

    public static func record(_ id: Int64) -> String { "record:\(id)" }
    public static func entity(_ id: Int64) -> String { "entity:\(id)" }
}

extension Link: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "link"
    public enum Columns {
        public static let src = Column("src")
        public static let dst = Column("dst")
        public static let rel = Column("rel")
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
