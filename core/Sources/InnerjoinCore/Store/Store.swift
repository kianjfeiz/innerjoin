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

        // v3 — make what the model understood searchable too. Without this, ⌘K can
        // only find words that appear literally in a file, not the titles, summaries,
        // and field values that are the whole point of understanding a document.
        m.registerMigration("v3_record_search") { db in
            try db.create(virtualTable: "recordSearch", using: FTS5()) { t in
                t.synchronize(withTable: "record")
                t.column("title")
                t.column("summary")
                t.column("category")
                t.column("fields")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
        }

        // v4 — a name that says what the document is, kept beside the one it arrived
        // with rather than replacing it. Nullable, so every existing library gets the
        // column without a rewrite and fills it in the next time it understands.
        m.registerMigration("v4_display_name") { db in
            try db.alter(table: "document") { t in
                t.add(column: "displayName", .text)
            }
        }

        // v5 — keep the model's own category guess apart from the category the graph
        // assigned. They were one column, so every clustering pass overwrote the
        // evidence it needed on the next pass: after one run the votes were no longer
        // the model's opinions but our own previous answer, read back as if independent.
        m.registerMigration("v5_category_hint") { db in
            try db.alter(table: "record") { t in
                t.add(column: "categoryHint", .text)
            }
            // Before any clustering has run, today's category *is* the guess.
            try db.execute(sql: "UPDATE record SET categoryHint = category WHERE categoryHint IS NULL")
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

    /// Every document, oldest first. Used by the passes that look at the whole library.
    public func allDocuments() throws -> [Document] {
        try dbQueue.read { db in
            try Document.order(Document.Columns.id).fetchAll(db)
        }
    }

    /// Derived names already in use, so a second document with the same subject gets
    /// numbered rather than quietly showing the same name twice.
    public func displayNames(excluding documentID: Int64? = nil) throws -> Set<String> {
        try dbQueue.read { db in
            var request = Document.filter(Column("displayName") != nil)
            if let documentID { request = request.filter(Document.Columns.id != documentID) }
            return Set(try request.fetchAll(db).compactMap(\.displayName))
        }
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

    /// What a query matched, and why — so a result can say whether it came from the
    /// document itself or from what was understood about it.
    public struct Hit: Sendable {
        public let document: Document
        public let record: Record?
        public let matchedRecord: Bool
    }

    /// Searches both layers at once: the text of the file, and the understanding built
    /// from it. Record matches rank first — a hit on an extracted title or amount is a
    /// better answer than a hit buried in body text.
    public func find(_ query: String, limit: Int = 20) throws -> [Hit] {
        try dbQueue.read { db in
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }

            let recordRows = try Record.fetchAll(db, sql: """
                SELECT record.* FROM record
                JOIN recordSearch ON recordSearch.rowid = record.id
                WHERE recordSearch MATCH ? ORDER BY bm25(recordSearch) LIMIT ?
                """, arguments: [pattern, limit])

            var hits: [Hit] = []
            var seen = Set<Int64>()
            for record in recordRows {
                guard let document = try Document.fetchOne(db, key: record.documentID) else { continue }
                seen.insert(record.documentID)
                hits.append(Hit(document: document, record: record, matchedRecord: true))
            }

            let documentRows = try Document.fetchAll(db, sql: """
                SELECT document.* FROM document
                JOIN documentSearch ON documentSearch.rowid = document.id
                WHERE documentSearch MATCH ? ORDER BY bm25(documentSearch) LIMIT ?
                """, arguments: [pattern, limit])

            for document in documentRows {
                guard let id = document.id, !seen.contains(id) else { continue }
                let record = try Record.filter(Record.Columns.documentID == id).fetchOne(db)
                hits.append(Hit(document: document, record: record, matchedRecord: false))
            }
            return Array(hits.prefix(limit))
        }
    }

    /// Retrieval for a question asked in words, rather than a search for terms.
    ///
    /// `find` requires every token to match, which is right when someone types "lease
    /// penalty" and wrong when they ask "how much is my rent?" — the question words
    /// appear in no document and the whole query returns nothing. So: drop the words
    /// that carry no meaning, try for all of what's left, and widen to any of it when
    /// that finds nothing.
    public func retrieve(_ question: String, limit: Int = 10) throws -> [Hit] {
        let terms = Store.contentWords(of: question)
        guard !terms.isEmpty else { return [] }

        let text = terms.joined(separator: " ")
        let narrow = try find(text, limit: limit)
        if !narrow.isEmpty { return narrow }

        // Nothing matched every word. Ask for any of them and let bm25 rank.
        return try dbQueue.read { db in
            guard let pattern = FTS5Pattern(matchingAnyTokenIn: text) else { return [] }
            let records = try Record.fetchAll(db, sql: """
                SELECT record.* FROM record
                JOIN recordSearch ON recordSearch.rowid = record.id
                WHERE recordSearch MATCH ? ORDER BY bm25(recordSearch) LIMIT ?
                """, arguments: [pattern, limit])

            var hits: [Hit] = []
            var seen = Set<Int64>()
            for record in records {
                guard let document = try Document.fetchOne(db, key: record.documentID) else { continue }
                seen.insert(record.documentID)
                hits.append(Hit(document: document, record: record, matchedRecord: true))
            }
            let documents = try Document.fetchAll(db, sql: """
                SELECT document.* FROM document
                JOIN documentSearch ON documentSearch.rowid = document.id
                WHERE documentSearch MATCH ? ORDER BY bm25(documentSearch) LIMIT ?
                """, arguments: [pattern, limit])
            for document in documents {
                guard let id = document.id, !seen.contains(id) else { continue }
                let record = try Record.filter(Record.Columns.documentID == id).fetchOne(db)
                hits.append(Hit(document: document, record: record, matchedRecord: false))
            }
            return Array(hits.prefix(limit))
        }
    }

    /// The words in a question that a document might actually contain.
    public static func contentWords(of question: String) -> [String] {
        question
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count > 1 && !questionWords.contains($0) }
    }

    /// Question and function words. Deliberately short: over-trimming throws away the
    /// noun someone was actually asking about.
    private static let questionWords: Set<String> = [
        "what", "whats", "when", "where", "who", "whos", "whom", "which", "why", "how",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "can",
        "could", "should", "would", "will", "shall", "have", "has", "had",
        "the", "a", "an", "of", "to", "in", "on", "at", "for", "from", "by", "with",
        "and", "or", "but", "if", "then", "than", "that", "this", "these", "those",
        "it", "its", "my", "me", "i", "you", "your", "our", "we", "they", "them",
        "there", "here", "about", "any", "all", "some", "much", "many", "most",
        "get", "got", "tell", "show", "find", "know", "need", "want", "please",
    ]

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

    /// What a category has learned to call things.
    ///
    /// Left to itself a model will call the same fact `rent_monthly` on one lease,
    /// `monthly_rent` on the next and `rent_amount` on the third — three columns where
    /// there should be one, and a table that can never be summed. Feeding back the
    /// names already in use is what makes a category converge on a schema instead of
    /// accumulating synonyms.
    public func fieldVocabulary(for category: String?, limit: Int = 14) throws -> [String] {
        try dbQueue.read { db in
            let records: [Record]
            if let category, !category.isEmpty {
                records = try Record.filter(Record.Columns.category == category).fetchAll(db)
            } else {
                records = try Record.order(Record.Columns.id.desc).limit(80).fetchAll(db)
            }
            var counts: [String: Int] = [:]
            for record in records {
                for name in record.fields.keys { counts[name, default: 0] += 1 }
            }
            return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(limit).map(\.key)
        }
    }

    /// A previous record from the same category, to show rather than describe.
    ///
    /// One worked example teaches a model more about what a good extraction of *this
    /// kind of document* looks like than another paragraph of instructions.
    public func exemplar(for category: String?) throws -> Record? {
        guard let category, !category.isEmpty else { return nil }
        return try dbQueue.read { db in
            // The richest example available: most fields, so it demonstrates the most.
            try Record.filter(Record.Columns.category == category)
                .fetchAll(db)
                .filter { !$0.fields.isEmpty }
                .max { $0.fields.count < $1.fields.count }
        }
    }

    /// Who a record is with, and how. One query rather than a link fetch followed by an
    /// entity fetch each — this runs for every document that gets named.
    public func parties(ofRecord recordID: Int64) throws -> [Naming.Party] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT entity.name AS name, entity.kind AS kind,
                       link.rel AS rel, link.confidence AS confidence
                FROM link JOIN entity ON link.dst = 'entity:' || entity.id
                WHERE link.src = ?
                """, arguments: ["record:\(recordID)"])
            .map { row in
                Naming.Party(
                    name: row["name"] as String? ?? "",
                    kind: Entity.Kind(rawValue: row["kind"] as String? ?? "") ?? .other,
                    relation: row["rel"] as String? ?? "mentions",
                    confidence: row["confidence"] as Double? ?? 1
                )
            }
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

    /// Whether the graph is healthy or bloating.
    ///
    /// Two numbers matter. **Singletons** — entities touching exactly one record — are
    /// the signature of over-production: a real entity eventually recurs, an invented
    /// one never does. **Hubs** are the opposite failure: an entity attached to most of
    /// the library carries no information and will wreck clustering, the way a stopword
    /// wrecks a search index.
    public struct GraphHealth: Sendable {
        public let records: Int
        public let entities: Int
        public let links: Int
        public let entitiesPerRecord: Double
        public let singletons: Int
        public let singletonShare: Double
        public let hubs: [(name: String, records: Int, share: Double)]
        public let relations: [(name: String, count: Int)]
    }

    public func graphHealth(hubThreshold: Double = 0.4) throws -> GraphHealth {
        try dbQueue.read { db in
            let records = try Record.fetchCount(db)
            let entities = try Entity.fetchCount(db)
            let links = try Link.fetchCount(db)

            let counts = try Row.fetchAll(db, sql: """
                SELECT entity.name AS name, COUNT(DISTINCT link.src) AS n
                FROM entity LEFT JOIN link ON link.dst = 'entity:' || entity.id
                GROUP BY entity.id ORDER BY n DESC
                """)
            let singletons = counts.filter { ($0["n"] as Int? ?? 0) == 1 }.count
            let hubs = counts.compactMap { row -> (String, Int, Double)? in
                let n = row["n"] as Int? ?? 0
                let share = records > 0 ? Double(n) / Double(records) : 0
                guard n > 1, share >= hubThreshold else { return nil }
                return (row["name"] as String? ?? "?", n, share)
            }
            let relations = try Row.fetchAll(db, sql: """
                SELECT rel AS name, COUNT(*) AS n FROM link GROUP BY rel ORDER BY n DESC
                """).map { ($0["name"] as String? ?? "?", $0["n"] as Int? ?? 0) }

            return GraphHealth(
                records: records, entities: entities, links: links,
                entitiesPerRecord: records > 0 ? Double(entities) / Double(records) : 0,
                singletons: singletons,
                singletonShare: entities > 0 ? Double(singletons) / Double(entities) : 0,
                hubs: hubs, relations: relations
            )
        }
    }

    public func links(from recordID: Int64) throws -> [Link] {
        try dbQueue.read { db in
            try Link.filter(Link.Columns.src == "record:\(recordID)").fetchAll(db)
        }
    }
}
