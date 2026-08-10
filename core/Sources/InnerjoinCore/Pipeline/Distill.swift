import Foundation
import GRDB

/// Stage 3 — turns a document's markdown into a record, with entities and dates.
///
/// One model call per document. Everything it returns is checked before it's written:
/// a citation that doesn't resolve is dropped, a date that can't be parsed is dropped,
/// and a document whose call fails keeps its markdown and stays searchable.
public struct Distill: Sendable {
    let store: Store
    let provider: any ModelProvider
    /// Renditions longer than this are truncated rather than split, for now. Documents
    /// this size are rare, and a bad split is worse than a shortened one.
    let maxPromptCharacters = 220_000
    let maxOutputTokens = 4_000

    public init(store: Store, provider: any ModelProvider) {
        self.store = store
        self.provider = provider
    }

    public struct Result: Sendable {
        public let record: Record
        public let entityCount: Int
        public let dateCount: Int
        /// Citations the model invented, which were dropped. Non-zero means the prompt
        /// needs work — worth watching rather than hiding.
        public let droppedCitations: Int
    }

    /// Understands one already-rendered document.
    @discardableResult
    public func understand(documentID: Int64) async throws -> Result {
        guard let document = try store.document(id: documentID) else {
            throw DistillError.noSuchDocument(documentID)
        }
        guard let markdown = document.markdown, !markdown.trimmed.isEmpty else {
            throw DistillError.notRendered(document.name)
        }

        let elements = try store.elements(of: documentID)
        let byTag = Dictionary(elements.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })
        let categories = try store.categoryNames()

        let prompt = String(markdown.prefix(maxPromptCharacters))
        let data = try await provider.extract(
            system: Prompt.system(categories: categories),
            user: Prompt.user(name: document.name, markdown: prompt),
            schema: Prompt.schema,
            maxTokens: maxOutputTokens
        )

        let reply = try Reply(data: data)
        var dropped = 0

        // Every cited tag must exist on this document. A model that invents "e99"
        // would otherwise produce a citation that can't be opened.
        func resolve(_ tag: String?) -> Element? {
            guard let tag else { return nil }
            guard let element = byTag[tag] else { dropped += 1; return nil }
            return element
        }

        var fields: [String: FieldValue] = [:]
        for field in reply.fields where !field.name.trimmed.isEmpty {
            let element = resolve(field.source)
            fields[field.name] = FieldValue(
                value: field.value, unit: field.unit,
                source: element?.tag, page: element?.page, box: element?.box
            )
        }

        var record = Record(
            documentID: documentID,
            kind: reply.kind,
            title: reply.title.trimmed.isEmpty ? document.name : reply.title.trimmed,
            summary: reply.summary,
            category: reply.category?.trimmed,
            happenedOn: reply.happenedOn.flatMap(Dates.parse),
            amount: reply.amount,
            currency: reply.currency,
            fields: fields
        )

        let dates = reply.dates.compactMap { proposed -> RecordDate? in
            guard let date = Dates.parse(proposed.date), Dates.isPlausible(date) else { return nil }
            return RecordDate(recordID: 0, kind: proposed.kind, date: date,
                              source: resolve(proposed.source)?.tag)
        }

        let resolvedEntities = try await resolveEntities(reply.entities, documentID: documentID)

        let draft = record
        record = try await store.dbQueue.write { db -> Record in
            // Re-running replaces cleanly rather than accumulating.
            try Record.filter(Record.Columns.documentID == documentID).deleteAll(db)
            var saved = draft
            try saved.insert(db)
            guard let recordID = saved.id else { return saved }

            for var date in dates {
                date.recordID = recordID
                try date.insert(db)
            }
            for (entityID, relation) in resolvedEntities {
                var link = Link(src: Link.record(recordID), rel: relation,
                                dst: Link.entity(entityID), documentID: documentID)
                try? link.insert(db)   // the unique index makes repeats a no-op
            }
            var updated = document
            updated.stage = .understood
            try updated.update(db)
            return saved
        }

        // Deadlines innerjoin works out itself — never arithmetic asked of a model.
        try await addDerivedDates(for: record, reply: reply)

        return Result(record: record, entityCount: resolvedEntities.count,
                      dateCount: dates.count, droppedCitations: dropped)
    }

    /// Resolves proposed entities against what's already known.
    ///
    /// Exact match on the normalized name catches the large majority. Fuzzy matching
    /// and model adjudication belong to Stage 4; doing the cheap rung now means the
    /// graph is useful immediately without pretending to be clever.
    private func resolveEntities(_ proposed: [Reply.ProposedEntity], documentID: Int64) async throws
        -> [(entityID: Int64, relation: String)]
    {
        var out: [(Int64, String)] = []
        for candidate in proposed {
            let name = candidate.name.trimmed
            guard name.count > 1 else { continue }
            let kind = Entity.Kind(rawValue: candidate.kind ?? "other") ?? .other
            let normalized = Entity.normalize(name)
            guard !normalized.isEmpty else { continue }

            let entityID = try await store.dbQueue.write { db -> Int64? in
                if var existing = try Entity
                    .filter(Entity.Columns.normName == normalized && Entity.Columns.kind == kind.rawValue)
                    .fetchOne(db)
                {
                    if existing.name != name, !existing.aliases.contains(name) {
                        existing.aliases.append(name)
                        try existing.update(db)
                    }
                    return existing.id
                }
                var fresh = Entity(name: name, kind: kind)
                try fresh.insert(db)
                return fresh.id
            }
            if let entityID {
                out.append((entityID, candidate.relation?.trimmed.nilIfEmpty ?? "mentions"))
            }
        }
        return out
    }

    /// A notice deadline is a term end minus a notice period. Computing it here keeps
    /// it deterministic and testable, and keeps arithmetic out of the model's hands.
    private func addDerivedDates(for record: Record, reply: Reply) async throws {
        guard let recordID = record.id else { return }
        guard let noticeDays = reply.noticeDays, noticeDays > 0 else { return }
        guard let end = reply.dates
            .first(where: { $0.kind == "term_end" || $0.kind == "expires" })
            .flatMap({ Dates.parse($0.date) }) else { return }
        guard let deadline = Calendar.current.date(byAdding: .day, value: -noticeDays, to: end) else { return }

        let derived = RecordDate(recordID: recordID, kind: "notice_deadline",
                                 date: deadline, derived: true)
        try await store.dbQueue.write { db in
            var row = derived
            try row.insert(db)
        }
    }
}

public enum DistillError: LocalizedError {
    case noSuchDocument(Int64)
    case notRendered(String)

    public var errorDescription: String? {
        switch self {
        case .noSuchDocument(let id): return "There's no document with id \(id)."
        case .notRendered(let name):  return "\(name) hasn't been read yet."
        }
    }
}

// MARK: - Dates

enum Dates {
    /// Accepts what models actually emit, in order of likelihood.
    static func parse(_ text: String?) -> Date? {
        guard let text = text?.trimmed, !text.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy", "dd/MM/yyyy",
                       "MMMM d, yyyy", "MMM d, yyyy", "yyyy-MM", "yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Guards against a misparse turning into a bogus deadline in someone's briefing.
    static func isPlausible(_ date: Date) -> Bool {
        let year = Calendar.current.component(.year, from: date)
        return year >= 1900 && year <= Calendar.current.component(.year, from: Date()) + 60
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
