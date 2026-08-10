import Foundation
import GRDB

/// One extracted fact, and where in the document it came from.
///
/// Values are kept as strings: they're for display and citation, and a string
/// round-trips exactly across every model provider. The two things innerjoin
/// actually queries on — a date and an amount — are typed columns on `Record`.
public struct FieldValue: Codable, Equatable, Sendable {
    public var value: String
    public var unit: String?
    /// Short element tag ("e12") the model cited. Resolved to page and box on read.
    public var source: String?
    public var page: Int?
    public var box: BBox?

    public init(value: String, unit: String? = nil, source: String? = nil,
                page: Int? = nil, box: BBox? = nil) {
        self.value = value
        self.unit = unit
        self.source = source
        self.page = page
        self.box = box
    }
}

/// What innerjoin understood from a document. One document, one record.
public struct Record: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var documentID: Int64

    /// What sort of thing this is — lease, invoice, policy, memo. Model-proposed.
    public var kind: String?
    public var title: String
    public var summary: String?
    /// The model's category guess. Once graph clustering exists it becomes a prior,
    /// not the decider.
    public var category: String?

    /// The date this document is *about*, which is rarely the date it was added.
    public var happenedOn: Date?
    /// Primary amount, for sorting and totals. The exact string stays in `fields`.
    public var amount: Double?
    public var currency: String?

    public var fields: [String: FieldValue]
    public var createdAt: Date

    public init(
        id: Int64? = nil, documentID: Int64, kind: String? = nil, title: String,
        summary: String? = nil, category: String? = nil, happenedOn: Date? = nil,
        amount: Double? = nil, currency: String? = nil,
        fields: [String: FieldValue] = [:], createdAt: Date = Date()
    ) {
        self.id = id; self.documentID = documentID; self.kind = kind; self.title = title
        self.summary = summary; self.category = category; self.happenedOn = happenedOn
        self.amount = amount; self.currency = currency; self.fields = fields
        self.createdAt = createdAt
    }
}

extension Record: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "record"

    public enum Columns {
        public static let id = Column("id")
        public static let documentID = Column("documentID")
        public static let category = Column("category")
        public static let happenedOn = Column("happenedOn")
        public static let amount = Column("amount")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["documentID"] = documentID
        container["kind"] = kind
        container["title"] = title
        container["summary"] = summary
        container["category"] = category
        container["happenedOn"] = happenedOn
        container["amount"] = amount
        container["currency"] = currency
        container["createdAt"] = createdAt
        container["fields"] = String(data: try JSONEncoder().encode(fields), encoding: .utf8)
    }

    public init(row: Row) throws {
        id = row["id"]; documentID = row["documentID"]; kind = row["kind"]
        title = row["title"]; summary = row["summary"]; category = row["category"]
        happenedOn = row["happenedOn"]; amount = row["amount"]; currency = row["currency"]
        createdAt = row["createdAt"]
        if let json: String = row["fields"], let data = json.data(using: .utf8) {
            fields = (try? JSONDecoder().decode([String: FieldValue].self, from: data)) ?? [:]
        } else {
            fields = [:]
        }
    }
}

/// A date pulled out of a document — a lease ending, a warranty expiring, a payment
/// due. Its own table because "what's coming up" is the query the product is built on,
/// and that wants an index.
public struct RecordDate: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var recordID: Int64
    /// term_end, expires, due, notice_deadline, renewal, signed…
    public var kind: String
    public var date: Date
    /// True when innerjoin computed it rather than reading it — a notice deadline
    /// counted back from a term end. Computed in Swift, never asked of a model.
    public var derived: Bool
    public var source: String?

    public init(id: Int64? = nil, recordID: Int64, kind: String, date: Date,
                derived: Bool = false, source: String? = nil) {
        self.id = id; self.recordID = recordID; self.kind = kind
        self.date = date; self.derived = derived; self.source = source
    }
}

extension RecordDate: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "recordDate"
    public enum Columns {
        public static let date = Column("date")
        public static let recordID = Column("recordID")
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
