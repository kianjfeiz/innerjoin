import Foundation
import GRDB

/// The workspace database. One SQLite file per workspace — it *is* the store, so
/// backing up, syncing, or deleting a workspace is a file operation.
///
/// Migrations are additive and versioned: later stages add their own tables rather
/// than shipping empty ones up front.
public final class Store: Sendable {
    /// A pool, not a queue: the UI needs to read while ingestion writes. GRDB puts
    /// pools in WAL mode, which is what makes that concurrency safe.
    public let dbQueue: DatabasePool
    public let vault: Vault

    /// Opens (creating if needed) the workspace at `root`.
    ///
    /// Layout:
    ///   root/innerjoin.sqlite   — the database
    ///   root/files/…            — the vault of originals
    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.vault = try Vault(root: root.appendingPathComponent("files", isDirectory: true))

        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabasePool(
            path: root.appendingPathComponent("innerjoin.sqlite").path,
            configuration: config
        )
        try Store.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        // v1 — everything the on-device preprocessor produces. No model required.
        m.registerMigration("v1_documents_and_elements") { db in
            try db.create(table: "document") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("vaultPath", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sha256", .text).notNull().unique()   // one file, one entry
                t.column("typeIdentifier", .text).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("pageCount", .integer)
                t.column("createdAt", .datetime)
                t.column("addedAt", .datetime).notNull()
                t.column("markdown", .text)
                t.column("stage", .text).notNull()
                t.column("status", .text).notNull()
                t.column("problem", .text)
            }
            try db.create(indexOn: "document", columns: ["addedAt"])
            try db.create(indexOn: "document", columns: ["stage"])

            try db.create(table: "element") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("document", onDelete: .cascade).notNull()
                t.column("position", .integer).notNull()
                t.column("tag", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("page", .integer)
                t.column("box", .text)          // JSON [x,y,w,h], top-left origin
                t.column("depth", .integer).notNull().defaults(to: 0)
                t.column("confidence", .double)
                t.uniqueKey(["documentID", "tag"])
            }
            try db.create(indexOn: "element", columns: ["documentID", "position"])

            // Full-text search over the markdown. Available with zero model calls,
            // which is what makes the app useful before a key is connected.
            try db.create(virtualTable: "documentSearch", using: FTS5()) { t in
                t.synchronize(withTable: "document")
                t.column("name")
                t.column("markdown")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
        }

        return m
    }

    // MARK: - Reads used by the CLI and, later, the app

    public func document(sha256: String) throws -> Document? {
        try dbQueue.read { db in
            try Document.filter(Document.Columns.sha256 == sha256).fetchOne(db)
        }
    }

    public func document(id: Int64) throws -> Document? {
        try dbQueue.read { db in try Document.fetchOne(db, key: id) }
    }

    public func recentDocuments(limit: Int = 50) throws -> [Document] {
        try dbQueue.read { db in
            try Document.order(Document.Columns.addedAt.desc).limit(limit).fetchAll(db)
        }
    }

    public func elements(of documentID: Int64) throws -> [Element] {
        try dbQueue.read { db in
            try Element
                .filter(Element.Columns.documentID == documentID)
                .order(Element.Columns.position)
                .fetchAll(db)
        }
    }

    /// Full-text search over document names and markdown. Works with no model connected.
    public func search(_ query: String, limit: Int = 20) throws -> [Document] {
        try dbQueue.read { db in
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
            return try Document.fetchAll(db, sql: """
                SELECT document.* FROM document
                JOIN documentSearch ON documentSearch.rowid = document.id
                WHERE documentSearch MATCH ?
                ORDER BY bm25(documentSearch)
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    public func counts() throws -> (documents: Int, elements: Int) {
        try dbQueue.read { db in
            (try Document.fetchCount(db), try Element.fetchCount(db))
        }
    }
}
