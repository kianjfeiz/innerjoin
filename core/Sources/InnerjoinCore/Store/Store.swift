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

        // v2 — what a model adds. Kept separate so a library parsed without a key
        // never carries empty tables it might never use.
        m.registerMigration("v2_records_and_graph") { db in
            try db.create(table: "record") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("document", onDelete: .cascade).notNull().unique()  // one doc, one record
                t.column("kind", .text)
                t.column("title", .text).notNull()
                t.column("summary", .text)
                t.column("category", .text)
                t.column("happenedOn", .datetime)
                t.column("amount", .double)
                t.column("currency", .text)
                t.column("fields", .text).notNull().defaults(to: "{}")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "record", columns: ["category"])
            try db.create(indexOn: "record", columns: ["happenedOn"])

            try db.create(table: "entity") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("normName", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("aliases", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["normName", "kind"])
            }

            try db.create(table: "link") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("src", .text).notNull()
                t.column("rel", .text).notNull()
                t.column("dst", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("documentID", .integer).references("document", onDelete: .cascade)
                t.uniqueKey(["src", "rel", "dst"])
            }
            try db.create(indexOn: "link", columns: ["src"])
            try db.create(indexOn: "link", columns: ["dst"])

            try db.create(table: "recordDate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("record", onDelete: .cascade).notNull()
                t.column("kind", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("derived", .boolean).notNull().defaults(to: false)
                t.column("source", .text)
            }
            try db.create(indexOn: "recordDate", columns: ["date"])
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

    // MARK: - Records and graph

    public func record(ofDocument documentID: Int64) throws -> Record? {
        try dbQueue.read { db in
            try Record.filter(Record.Columns.documentID == documentID).fetchOne(db)
        }
    }

    public func records(limit: Int = 100) throws -> [Record] {
        try dbQueue.read { db in
            try Record.order(Record.Columns.happenedOn.desc).limit(limit).fetchAll(db)
        }
    }

    /// Categories currently in use, most-used first — the taxonomy handed to the model.
    public func categoryNames() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT category FROM record
                WHERE category IS NOT NULL AND category <> ''
                GROUP BY category ORDER BY COUNT(*) DESC LIMIT 40
                """)
        }
    }

    public func dates(ofRecord recordID: Int64) throws -> [RecordDate] {
        try dbQueue.read { db in
            try RecordDate
                .filter(RecordDate.Columns.recordID == recordID)
                .order(RecordDate.Columns.date)
                .fetchAll(db)
        }
    }

    /// Everything with a date between now and `days` out — the query the Today
    /// briefing is built on.
    public func upcoming(withinDays days: Int = 180) throws -> [(date: RecordDate, record: Record)] {
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        return try dbQueue.read { db in
            let dates = try RecordDate
                .filter(RecordDate.Columns.date >= now && RecordDate.Columns.date <= horizon)
                .order(RecordDate.Columns.date)
                .fetchAll(db)
            let records = try Record.fetchAll(db, keys: Set(dates.map(\.recordID)))
            let byID = Dictionary(records.compactMap { record in
                record.id.map { ($0, record) }
            }, uniquingKeysWith: { first, _ in first })
            return dates.compactMap { date in
                byID[date.recordID].map { (date, $0) }
            }
        }
    }

    public func entities(limit: Int = 100) throws -> [Entity] {
        try dbQueue.read { db in
            try Entity.order(Entity.Columns.name).limit(limit).fetchAll(db)
        }
    }

    /// Every record connected to an entity — one query, and the whole dossier.
    public func records(linkedTo entityID: Int64) throws -> [Record] {
        try dbQueue.read { db in
            try Record.fetchAll(db, sql: """
                SELECT record.* FROM record
                JOIN link ON link.src = 'record:' || record.id
                WHERE link.dst = ?
                ORDER BY record.happenedOn DESC
                """, arguments: ["entity:\(entityID)"])
        }
    }

    public func links(from recordID: Int64) throws -> [Link] {
        try dbQueue.read { db in
            try Link.filter(Link.Columns.src == "record:\(recordID)").fetchAll(db)
        }
    }
}
