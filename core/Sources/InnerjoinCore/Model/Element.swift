import Foundation
import GRDB

/// A normalized rectangle on a page. Origin top-left, values 0...1.
///
/// Vision reports bottom-left origin and PDFKit works in points — both are converted
/// here, once, inside their partitioner. Everything downstream can assume this shape.
public struct BBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// Convert from a bottom-left-origin normalized rect (Vision's convention).
    public static func fromBottomLeft(x: Double, y: Double, width: Double, height: Double) -> BBox {
        BBox(x: x, y: 1.0 - y - height, width: width, height: height)
    }
}

/// What a piece of a document is. Mirrors Unstructured's taxonomy so renditions,
/// tooling, and any future swap to their API all speak the same language.
public enum ElementKind: String, Codable, CaseIterable, Sendable {
    case title
    case text
    case listItem
    case table
    case image
    case pageHeader   // repeated furniture — dropped from renditions
    case pageFooter
    case pageNumber
    case caption
    case code
    case other
}

/// One piece of a document, in reading order, with the coordinates it was found at.
///
/// Elements are parser scaffolding, not a user-facing concept: they exist so a fact
/// can point back at the exact spot on the page it came from. Cached because
/// re-running OCR is expensive.
public struct Element: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var documentID: Int64

    /// Reading order within the document.
    public var position: Int
    /// Short, stable handle used in renditions and citations — "e12". Cheap in tokens.
    public var tag: String

    public var kind: ElementKind
    public var text: String

    /// 1-based. Nil for formats without pages (DOCX, email, CSV, transcripts).
    public var page: Int?
    public var box: BBox?
    /// Heading depth for titles, nesting depth for list items.
    public var depth: Int
    /// OCR confidence 0...1. Nil when the text came from a real text layer.
    public var confidence: Double?

    public init(
        id: Int64? = nil,
        documentID: Int64,
        position: Int,
        tag: String,
        kind: ElementKind,
        text: String,
        page: Int? = nil,
        box: BBox? = nil,
        depth: Int = 0,
        confidence: Double? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.position = position
        self.tag = tag
        self.kind = kind
        self.text = text
        self.page = page
        self.box = box
        self.depth = depth
        self.confidence = confidence
    }

    public static func tag(for position: Int) -> String { "e\(position)" }
}

extension Element: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "element"

    public enum Columns {
        public static let id = Column("id")
        public static let documentID = Column("documentID")
        public static let position = Column("position")
        public static let tag = Column("tag")
        public static let kind = Column("kind")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // BBox is stored as a compact JSON string; SQLite has no rect type and a
    // separate table for four doubles would be pure ceremony.
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["documentID"] = documentID
        container["position"] = position
        container["tag"] = tag
        container["kind"] = kind.rawValue
        container["text"] = text
        container["page"] = page
        container["depth"] = depth
        container["confidence"] = confidence
        container["box"] = box.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
    }

    public init(row: Row) throws {
        id = row["id"]
        documentID = row["documentID"]
        position = row["position"]
        tag = row["tag"]
        kind = ElementKind(rawValue: row["kind"]) ?? .other
        text = row["text"]
        page = row["page"]
        depth = row["depth"]
        confidence = row["confidence"]
        if let json: String = row["box"], let data = json.data(using: .utf8) {
            box = try? JSONDecoder().decode(BBox.self, from: data)
        } else {
            box = nil
        }
    }
}
