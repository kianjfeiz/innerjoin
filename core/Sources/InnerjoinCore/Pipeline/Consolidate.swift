import Foundation
import GRDB

/// Stage 4 — tidies the graph once documents have accumulated.
///
/// Resolution during ingest can only compare a name against what was known at the
/// time, so "Alcon" filed in March and "Alcon Laboratories" filed in July stay
/// separate. This pass looks at the whole graph at once and merges what turns out to
/// be the same thing, then flags places where two documents disagree.
///
/// Deterministic throughout: no model is consulted, so it costs nothing and can run
/// whenever the library is idle.
public struct Consolidate: Sendable {
    let store: Store

    /// Above this, two names of the same kind are the same entity. Set high on
    /// purpose — a wrong merge silently fuses two people's records, which is far
    /// worse than leaving a duplicate for a human to notice.
    public static let mergeThreshold = 0.90

    public init(store: Store) { self.store = store }

    public struct Outcome: Sendable {
        public let merged: [(kept: String, absorbed: String, why: String)]
        public let conflicts: [Conflict]
    }

    public struct Conflict: Sendable {
        public let field: String
        public let entity: String
        public let older: (title: String, value: String)
        public let newer: (title: String, value: String)
    }

    @discardableResult
    public func run() async throws -> Outcome {
        let merged = try await mergeDuplicateEntities()
        let conflicts = try await flagConflicts()
        return Outcome(merged: merged, conflicts: conflicts)
    }

    // MARK: - Merging

    /// Finds entities that are the same thing under different names and folds them
    /// together, keeping the one with more connections as the survivor.
    func mergeDuplicateEntities() async throws -> [(kept: String, absorbed: String, why: String)] {
        var report: [(String, String, String)] = []
        let entities = try store.entities(limit: 5_000)

        // Compare only within a kind: a person and a company sharing a name are not
        // the same thing, however similar the strings look.
        for kind in Entity.Kind.allCases {
            var group = entities.filter { $0.kind == kind }
            guard group.count > 1 else { continue }

            // Longer, more specific names win, so "Alcon" folds into "Alcon Laboratories"
            // rather than the other way round.
            group.sort { $0.normName.count > $1.normName.count }

            var absorbed = Set<Int64>()
            for (index, keeper) in group.enumerated() {
                guard let keeperID = keeper.id, !absorbed.contains(keeperID) else { continue }
                for candidate in group.dropFirst(index + 1) {
                    guard let candidateID = candidate.id, !absorbed.contains(candidateID) else { continue }
                    guard let why = Self.sameThing(keeper.normName, candidate.normName) else { continue }
                    try await merge(candidateID, into: keeperID, alias: candidate.name)
                    absorbed.insert(candidateID)
                    report.append((keeper.name, candidate.name, why))
                }
            }
        }
        return report
    }

    /// Two tests, both conservative.
    ///
    /// A **name prefix** catches the common real case — an organization referred to by
    /// its short form. It requires whole-word alignment so "Ann" never absorbs "Anna".
    /// **Trigram similarity** catches spelling drift and typos.
    public static func sameThing(_ longer: String, _ shorter: String) -> String? {
        guard longer != shorter, !longer.isEmpty, !shorter.isEmpty else { return nil }

        let longWords = longer.split(separator: " ")
        let shortWords = shorter.split(separator: " ")
        if shortWords.count < longWords.count,
           shortWords.count >= 1,
           shorter.count >= 4,
           Array(longWords.prefix(shortWords.count)) == shortWords {
            return "short form"
        }

        let score = similarity(longer, shorter)
        return score >= mergeThreshold ? String(format: "%.0f%% alike", score * 100) : nil
    }

    /// Dice coefficient over character trigrams.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let first = trigrams(a), second = trigrams(b)
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        return 2.0 * Double(first.intersection(second).count)
            / Double(first.count + second.count)
    }

    private static func trigrams(_ text: String) -> Set<String> {
        let padded = Array("  \(text) ")
        guard padded.count >= 3 else { return [] }
        return Set((0...(padded.count - 3)).map { String(padded[$0..<($0 + 3)]) })
    }

    /// Repoints every edge, folds in the aliases, then removes the absorbed entity.
    private func merge(_ absorbedID: Int64, into keeperID: Int64, alias: String) async throws {
        try await store.dbQueue.write { db in
            let from = "entity:\(absorbedID)", to = "entity:\(keeperID)"
            // The unique index on (src, rel, dst) rejects edges the keeper already has,
            // which is the deduplication we want.
            try db.execute(sql: "UPDATE OR IGNORE link SET dst = ? WHERE dst = ?", arguments: [to, from])
            try db.execute(sql: "UPDATE OR IGNORE link SET src = ? WHERE src = ?", arguments: [to, from])
            try db.execute(sql: "DELETE FROM link WHERE src = ? OR dst = ?", arguments: [from, from])

            if var keeper = try Entity.fetchOne(db, key: keeperID) {
                if !keeper.aliases.contains(alias) { keeper.aliases.append(alias) }
                if let absorbed = try Entity.fetchOne(db, key: absorbedID) {
                    for extra in absorbed.aliases where !keeper.aliases.contains(extra) {
                        keeper.aliases.append(extra)
                    }
                }
                try keeper.update(db)
            }
            try Entity.deleteOne(db, key: absorbedID)
        }
    }

    // MARK: - Conflicts

    /// Finds places where two records about the same entity state different values for
    /// the same field.
    ///
    /// Nothing is overwritten. Both records keep what they said, the disagreement
    /// becomes an edge, and the newer one is treated as current — which is exactly how
    /// an amended lease should behave.
    func flagConflicts() async throws -> [Conflict] {
        var found: [Conflict] = []

        let entities = try store.entities(limit: 5_000)
        for entity in entities {
            guard let entityID = entity.id else { continue }
            let records = try store.records(linkedTo: entityID)
            guard records.count > 1 else { continue }

            // Group by field name, then look for more than one distinct value.
            var byField: [String: [(record: Record, value: String)]] = [:]
            for record in records {
                for (name, field) in record.fields {
                    byField[name, default: []].append((record, field.value))
                }
            }

            for (name, entries) in byField {
                let distinct = Set(entries.map { Self.comparable($0.value) })
                guard distinct.count > 1 else { continue }

                let ordered = entries.sorted {
                    ($0.record.happenedOn ?? .distantPast) < ($1.record.happenedOn ?? .distantPast)
                }
                guard let older = ordered.first, let newer = ordered.last,
                      older.record.id != newer.record.id,
                      Self.comparable(older.value) != Self.comparable(newer.value) else { continue }

                if let oldID = older.record.id, let newID = newer.record.id {
                    try await store.dbQueue.write { db in
                        var link = Link(src: Link.record(newID), rel: "contradicts",
                                        dst: Link.record(oldID))
                        try? link.insert(db)
                    }
                }
                found.append(Conflict(
                    field: name, entity: entity.name,
                    older: (older.record.title, older.value),
                    newer: (newer.record.title, newer.value)
                ))
            }
        }
        return found
    }

    /// Values differing only in formatting aren't a disagreement. "$3,200.00" and
    /// "3200" say the same thing, and flagging that would train people to ignore flags.
    public static func comparable(_ value: String) -> String {
        let stripped = value.lowercased()
            .replacingOccurrences(of: #"[\s,$£€]"#, with: "", options: .regularExpression)
        if let number = Double(stripped) { return String(number) }
        if stripped.hasSuffix(".00"), let number = Double(stripped.dropLast(3)) {
            return String(number)
        }
        return stripped
    }
}
