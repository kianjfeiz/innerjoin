import Foundation
import GRDB
import UniformTypeIdentifiers

/// A file the user added. One file in, one row here — always, even if every later
/// stage fails. This row is the anchor everything else hangs off.
public struct Document: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?

    /// Path inside the vault, relative to the vault root. The user's original is never touched.
    public var vaultPath: String
    /// The name the file arrived with. Never overwritten — it's provenance, and someone
    /// will eventually go looking for the file by the name they gave it.
    public var name: String
    /// A name derived from what the document turned out to be, once it's understood:
    /// "2026-06-15 Travel insurance certificate — ACE.pdf". Nil until there's a record,
    /// or when nothing better than the arrival name could be built.
    public var displayName: String?
    /// Content hash. Dedupe key — re-adding the same bytes is a no-op.
    public var sha256: String
    /// Uniform type identifier, e.g. "com.adobe.pdf".
    public var typeIdentifier: String
    public var byteSize: Int64
    public var pageCount: Int?

    /// When the document itself was created (filesystem or EXIF), not when we ingested it.
    public var createdAt: Date?
    public var addedAt: Date

    /// Markdown rendition of the whole file — the agent-ready text. Nil until Stage 2 runs.
    public var markdown: String?

    public var stage: Stage
    public var status: Status
    /// Human-readable reason when `status` is `.failed`. Shown in the UI, so no stack traces.
    public var problem: String?

    public init(
        id: Int64? = nil,
        vaultPath: String,
        name: String,
        displayName: String? = nil,
        sha256: String,
        typeIdentifier: String,
        byteSize: Int64,
        pageCount: Int? = nil,
        createdAt: Date? = nil,
        addedAt: Date = Date(),
        markdown: String? = nil,
        stage: Stage = .added,
        status: Status = .ok,
        problem: String? = nil
    ) {
        self.id = id
        self.vaultPath = vaultPath
        self.name = name
        self.displayName = displayName
        self.sha256 = sha256
        self.typeIdentifier = typeIdentifier
        self.byteSize = byteSize
        self.pageCount = pageCount
        self.createdAt = createdAt
        self.addedAt = addedAt
        self.markdown = markdown
        self.stage = stage
        self.status = status
        self.problem = problem
    }

    /// How far this document got. Doubles as the resume point after a crash.
    public enum Stage: String, Codable, CaseIterable, Sendable {
        case added       // Stage 0 — in the vault and the database
        case parsed      // Stage 1 — elements extracted
        case rendered    // Stage 2 — markdown written
        case understood  // Stage 3 — record extracted (needs a model)
    }

    public enum Status: String, Codable, Sendable {
        case ok
        case partial  // usable, but something was skipped — e.g. 2 of 40 pages unreadable
        case failed   // nothing usable came out; `problem` says why
    }

    public var type: UTType? { UTType(typeIdentifier) }

    /// What to show. The derived name when there is one, otherwise the name it arrived
    /// with — so a document is never nameless while it waits to be understood.
    public var label: String { displayName ?? name }

    /// True when the library is showing a different name than the file arrived with.
    /// The UI uses this to offer the original, rather than hiding that it changed.
    public var wasRenamed: Bool { displayName != nil && displayName != name }
}

extension Document: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "document"

    public enum Columns {
        public static let id = Column("id")
        public static let sha256 = Column("sha256")
        public static let name = Column("name")
        public static let stage = Column("stage")
        public static let status = Column("status")
        public static let addedAt = Column("addedAt")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
