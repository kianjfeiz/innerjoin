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

    /// Whether to feed the library's accumulated vocabulary and examples back into
    /// the prompt. On by default; off is only useful for measuring what it's worth.
    let learningEnabled: Bool

    public init(store: Store, provider: any ModelProvider, learningEnabled: Bool = true) {
        self.store = store
        self.provider = provider
        self.learningEnabled = learningEnabled
    }

    /// Which category's lessons apply, guessed before the document is understood.
    ///
    /// A cheap keyword match, not a decision: getting it wrong costs a slightly less
    /// relevant example, and the graph reassigns the category properly afterwards.
    static func likelyCategory(of document: Document, markdown: String,
                               among categories: [String]) -> String? {
        let haystack = (document.name + " " + markdown.prefix(3_000)).lowercased()
        return categories
            .map { category -> (String, Int) in
                // Categories are named in the plural — "Invoices", "Policies" — while
                // the documents in them are singular. Matching only the exact word
                // means a category almost never recognizes its own members.
                let hits = Self.forms(of: category)
                    .map { haystack.components(separatedBy: $0).count - 1 }
                    .max() ?? 0
                return (category, hits)
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    /// A category name and the singular it was probably made from.
    static func forms(of category: String) -> [String] {
        let lower = category.lowercased()
        var forms = [lower]
        if lower.hasSuffix("ies") { forms.append(lower.dropLast(3) + "y") }
        else if lower.hasSuffix("es"), lower.count > 4 { forms.append(String(lower.dropLast(2))) }
        if lower.hasSuffix("s"), lower.count > 3 { forms.append(String(lower.dropLast())) }
        return forms
    }

    public struct Result: Sendable {
        public let record: Record
        public let entityCount: Int
        public let dateCount: Int
        /// Citations the model invented, which were dropped. Non-zero means the prompt
        /// needs work — worth watching rather than hiding.
        public let droppedCitations: Int
        /// Entities the gate turned away, with the reason. Surfaced rather than hidden:
        /// this list is how you tell whether extraction is over-producing.
        public let refusedEntities: [String]
        /// Durable facts about people this document contributed.
        public let assertionCount: Int
        /// How many the model offered, so "it proposed none" is distinguishable from
        /// "they were all refused" — those need opposite fixes.
        public let proposedAssertions: Int
        /// The name the document now carries, if understanding earned it a better one.
        public let name: String?
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
        // Everything the library has learned that bears on this document. The
        // category can only be guessed before extraction, so the guess comes from the
        // document's own name and text — good enough to fetch the right vocabulary.
        let categories = try store.categoryNames()
        let likely = Self.likelyCategory(of: document, markdown: markdown, among: categories)
        let learned = Prompt.Learned(
            categories: categories,
            fieldNames: learningEnabled ? try store.fieldVocabulary(for: likely) : [],
            exemplar: learningEnabled ? try store.exemplar(for: likely) : nil
        )

        let prompt = String(markdown.prefix(maxPromptCharacters))
        let data = try await provider.extract(
            system: Prompt.system(learned),
            user: Prompt.user(name: document.name, markdown: prompt),
            schema: Prompt.schema,
            maxTokens: maxOutputTokens
        )

        let reply = try Reply(data: data)
        var dropped = 0

        // Every cited tag must exist on this document. A model that invents "e99"
        // would otherwise produce a citation that can't be opened.
        func resolve(_ tag: String?) -> Element? {
            guard let cited = tag?.trimmed, !cited.isEmpty else { return nil }
            guard let normalized = Element.normalizeTag(cited) else { dropped += 1; return nil }
            guard let element = byTag[normalized] else { dropped += 1; return nil }
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
            title: Element.stripTags(reply.title).isEmpty
                ? document.name : Element.stripTags(reply.title),
            summary: reply.summary.map(Element.stripTags),
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

        let gate = EntityGate(documentText: markdown)
        let (resolvedEntities, refusedEntities, entitiesByName) =
            try await resolveEntities(reply.entities, gate: gate,
                                      documentID: documentID, documentText: markdown)

        let draft = record
        record = try await store.dbQueue.write { db -> Record in
            // Re-running replaces cleanly rather than accumulating.
            //
            // A link names its record as the string "record:42", not as a foreign key,
            // because one table has to hold record→entity and record→record edges alike.
            // The cost is that nothing cascades: deleting the record here and inserting
            // a replacement with a fresh id would leave every old edge in place, still
            // pointing at a row that no longer exists. Nothing would look wrong — until
            // clustering counts how many records an entity touches, sees the ghosts, and
            // decides the main supplier is attached to half the library and must be a
            // hub. That is what made five real runs disagree with each other: every
            // re-read inflated the graph a little more.
            let replaced = try Int64.fetchAll(
                db, sql: "SELECT id FROM record WHERE documentID = ?", arguments: [documentID])
            for old in replaced {
                try db.execute(sql: "DELETE FROM link WHERE src = ?", arguments: ["record:\(old)"])
            }
            try Record.filter(Record.Columns.documentID == documentID).deleteAll(db)
            var saved = draft
            try saved.insert(db)
            guard let recordID = saved.id else { return saved }

            for var date in dates {
                date.recordID = recordID
                try date.insert(db)
            }
            for admitted in resolvedEntities {
                var link = Link(src: Link.record(recordID), rel: admitted.relation,
                                dst: Link.entity(admitted.entityID),
                                confidence: admitted.confidence, documentID: documentID)
                try? link.insert(db)   // the unique index makes repeats a no-op
            }
            var updated = document
            updated.stage = .understood
            try updated.update(db)
            return saved
        }

        // What this document claims about the people it names — where they work, their
        // role, how to reach them. Rides the same call, so it costs nothing extra, and
        // is gated as strictly as the entities themselves.
        let memory = Memory(store: store)
        let remembered = try await memory.record(
            reply.assertions, subjects: entitiesByName, documentID: documentID,
            documentText: markdown, on: record.happenedOn,
            anchors: { resolve($0)?.tag })
        try await memory.refreshSeenDates()

        // Deadlines innerjoin works out itself — never arithmetic asked of a model.
        try await addDerivedDates(for: record, reply: reply)

        // Now that we know what the document is, it can be called what it is. Pure
        // string work over the record — no second model call.
        let name = try await Namer(store: store).name(documentID: documentID)

        return Result(record: record, entityCount: resolvedEntities.count,
                      dateCount: dates.count, droppedCitations: dropped,
                      refusedEntities: refusedEntities + remembered.refused,
                      assertionCount: remembered.kept,
                      proposedAssertions: reply.assertions.count, name: name)
    }

    struct AdmittedEntity: Sendable {
        let entityID: Int64
        let relation: String
        let confidence: Double
    }

    /// Puts proposed entities through the gate, then resolves survivors against what's
    /// already known.
    ///
    /// Two separate jobs, deliberately: the gate decides whether something is an entity
    /// at all, and resolution decides whether it's one we've already met. Exact match on
    /// the normalized name catches most duplicates; fuzzy matching belongs to Stage 4.
    private func resolveEntities(_ proposed: [Reply.ProposedEntity], gate: EntityGate,
                                 documentID: Int64, documentText: String) async throws
        -> (admitted: [AdmittedEntity], refused: [String], byName: [String: Int64])
    {
        var refused: [String] = []
        var candidates: [(name: String, kind: Entity.Kind, relation: String,
                          confidence: Double, mentions: Int, source: String?)] = []

        for entity in proposed {
            let name = entity.name.trimmed
            let kind = Entity.Kind(rawValue: entity.kind ?? "other") ?? .other
            switch gate.judge(name: name, kind: kind) {
            case .reject(let reason):
                refused.append("\(name) (\(reason))")
            case .admit(let confidence):
                candidates.append((name, kind,
                                   entity.relation?.trimmed.nilIfEmpty ?? "mentions",
                                   confidence, gate.mentions(of: name), entity.source))
            }
        }

        // A document naming thirty parties is describing scenery. Keep the ones the
        // document actually dwells on, and say what was dropped.
        if candidates.count > EntityGate.perDocumentLimit {
            candidates.sort {
                ($0.confidence, $0.mentions) > ($1.confidence, $1.mentions)
            }
            refused.append(contentsOf: candidates
                .dropFirst(EntityGate.perDocumentLimit)
                .map { "\($0.name) (over the per-document limit)" })
            candidates = Array(candidates.prefix(EntityGate.perDocumentLimit))
        }

        // Resolution runs through the ladder rather than exact-name matching. The
        // library's existing identities are fetched once, and each admitted name is
        // matched against them by identifier, then by name compatibility with
        // corroboration, then by name compatibility with no competing candidate. A name
        // that fits two people resolves to neither, and waits for a person.
        var known = try store.resolutionCandidates()
        let documentIdentifiers = Resolver.identifiers(in: documentText)

        var admitted: [AdmittedEntity] = []
        var resolvedThisDocument: Set<Int64> = []
        // Assertions name their subject by name, so they need the same mapping the
        // gate just produced — the alternative is a second round of resolution that
        // could disagree with the first.
        var byName: [String: Int64] = [:]

        for candidate in candidates {
            let outcome = Resolver.resolve(
                surface: candidate.name, kind: candidate.kind,
                identifiers: documentIdentifiers,
                alongside: resolvedThisDocument,
                among: known)

            let entityID: Int64?
            let how: Mention.Resolution
            if let outcome {
                entityID = outcome.entityID
                how = outcome.how
                // An identity met under a new spelling remembers the spelling.
                try await noteAlias(candidate.name, on: outcome.entityID)
            } else {
                how = .exact
                entityID = try await store.dbQueue.write { db -> Int64? in
                    var fresh = Entity(name: candidate.name, kind: candidate.kind)
                    try fresh.insert(db)
                    return fresh.id
                }
                // A document can name the same thing twice under different labels —
                // "M. Osei" as a person and again as an org. The candidate list was read
                // before the loop, so without this the second mention can't see the node
                // the first one just made, and mints a duplicate.
                if let entityID {
                    known.append(Resolver.Candidate(entityID: entityID, name: candidate.name,
                                                    kind: candidate.kind))
                }
            }
            guard let entityID else { continue }
            resolvedThisDocument.insert(entityID)

            // The mention is kept whatever happened, because it is the evidence. If this
            // resolution turns out to be wrong, re-pointing the mention fixes it without
            // re-reading anything.
            try await store.dbQueue.write { db in
                var mention = Mention(documentID: documentID, elementTag: candidate.source,
                                      surface: candidate.name, kind: candidate.kind,
                                      entityID: entityID, resolvedBy: how,
                                      confidence: outcome?.confidence ?? 1.0)
                try? mention.insert(db)   // the unique key makes a repeat a no-op
            }

            byName[Entity.normalize(candidate.name)] = entityID
            admitted.append(AdmittedEntity(entityID: entityID, relation: candidate.relation,
                                           confidence: candidate.confidence))
        }
        return (admitted, refused, byName)
    }

    /// Records a surface form we hadn't seen for an identity we already knew.
    private func noteAlias(_ surface: String, on entityID: Int64) async throws {
        try await store.dbQueue.write { db in
            guard var existing = try Entity.fetchOne(db, key: entityID) else { return }
            let known = Set(([existing.name] + existing.aliases).map(Entity.normalize))
            guard !known.contains(Entity.normalize(surface)) else { return }
            existing.aliases.append(surface)
            try existing.update(db)
        }
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

public enum Dates {
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

    /// The strict form only, for when a caller needs to know it really is a date.
    public static func parseISO(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
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
