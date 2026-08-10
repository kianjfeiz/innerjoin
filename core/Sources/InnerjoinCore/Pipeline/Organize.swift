import Foundation
import GRDB

/// Stage 6 — categories, discovered rather than configured.
///
/// A category here is a *cluster of the knowledge graph*: records that share the
/// people, places, and organizations they're about. Classifying each document alone is
/// a coin flip; classifying it by what it connects to is usually obvious. Three loose
/// travel receipts sit in "Everything else" until a flight confirmation and a hotel
/// invoice link them through a shared vendor — and then Travel is born already correct.
///
/// No model call. Membership comes from graph structure; the name comes from the
/// per-document guesses Stage 3 already made, which the cluster aggregates into a vote.
public struct Organize: Sendable {
    let store: Store

    /// A cluster becomes a category at this size. Below it, members wait in the
    /// holding category — this is the hysteresis that stops one odd file minting a
    /// category nobody wanted.
    public static let minimumMembers = 3

    /// An entity attached to more than this share of the library says nothing about
    /// any particular record. Left in, it wires everything to everything and collapses
    /// every cluster into one — the same reason search engines drop stopwords.
    ///
    /// Set at 0.6 rather than lower because a library naturally splits into a few
    /// groups: with two equal halves, the entity defining each one reaches 50%, and a
    /// stricter threshold would discard the very structure we're looking for.
    public static let hubShare = 0.6

    /// Hub-hunting only makes sense once there's a library to be a hub of. Below this
    /// many records, and below this many connections, every entity looks over-connected.
    static let hubMinimumRecords = 5
    static let hubMinimumReach = 3

    /// How many *distinct* entities must tie a record to a group before it joins.
    ///
    /// Held at 1 deliberately, after measuring both. Requiring two makes categories
    /// perfectly pure but strands a third of the library in "Everything else" — a
    /// utility bill shares only the address with the lease, and belongs with it. A
    /// sidebar where the biggest category is "Everything else" is the worse failure,
    /// so the occasional stray (a car registration pulled toward the health policies
    /// because both name the same insurer) is the better trade.
    ///
    /// The counting is by distinct entity rather than summed edge weight, which is
    /// what makes raising this meaningful at all: summing counts one shared name once
    /// per member of the group, so a single tie to a group of three already looks
    /// like three.
    static let minimumAttachment = 1

    public static let holdingCategory = "Everything else"

    public init(store: Store) { self.store = store }

    public struct Outcome: Sendable {
        public let categories: [(name: String, members: Int)]
        public let holding: Int
        public let ignoredHubs: [String]
    }

    @discardableResult
    public func run() async throws -> Outcome {
        let records = try store.records(limit: 10_000)
        guard records.count >= Self.minimumMembers else {
            return Outcome(categories: [], holding: records.count, ignoredHubs: [])
        }

        let (adjacency, entitiesByRecord, hubs) = try neighbours(of: records)
        let communities = Self.propagateLabels(over: adjacency,
                                               records: records.compactMap(\.id),
                                               entities: entitiesByRecord)

        // Group by community, then decide which are substantial enough to name.
        var members: [Int64: [Record]] = [:]
        for record in records {
            guard let id = record.id else { continue }
            members[communities[id].map(Int64.init) ?? id, default: []].append(record)
        }

        var assignments: [Int64: String] = [:]
        var named: [(String, Int)] = []
        var holding = 0
        var used = Set<String>()

        for group in members.values.sorted(by: { $0.count > $1.count }) {
            if group.count >= Self.minimumMembers {
                var name = Self.name(for: group)
                // Two clusters can vote for the same name. Keep them distinct rather
                // than silently fusing groups the graph says are separate.
                if used.contains(name), let distinguishing = Self.distinguisher(for: group) {
                    name = distinguishing
                }
                used.insert(name)
                named.append((name, group.count))
                for record in group { if let id = record.id { assignments[id] = name } }
            } else {
                holding += group.count
                for record in group { if let id = record.id { assignments[id] = Self.holdingCategory } }
            }
        }

        let finalAssignments = assignments
        try await store.dbQueue.write { db in
            for (recordID, category) in finalAssignments {
                try db.execute(sql: "UPDATE record SET category = ? WHERE id = ?",
                               arguments: [category, recordID])
            }
        }
        return Outcome(categories: named.sorted { $0.1 > $1.1 }, holding: holding,
                       ignoredHubs: hubs)
    }

    // MARK: - Structure

    /// Two records are neighbours when they're about the same entity, weighted by how
    /// many they share. Hub entities are left out entirely.
    func neighbours(of records: [Record]) throws
        -> (adjacency: [Int64: [Int64: Int]], entities: [Int64: Set<Int64>], hubs: [String])
    {
        let total = records.count
        var adjacency: [Int64: [Int64: Int]] = [:]
        var entitiesByRecord: [Int64: Set<Int64>] = [:]
        var hubs: [String] = []

        try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity.id AS entityID, entity.name AS name,
                       COUNT(DISTINCT link.src) AS reach
                FROM entity JOIN link ON link.dst = 'entity:' || entity.id
                WHERE link.src LIKE 'record:%'
                GROUP BY entity.id
                """)

            for row in rows {
                let reach = row["reach"] as Int? ?? 0
                guard reach > 1 else { continue }
                if total >= Self.hubMinimumRecords, reach >= Self.hubMinimumReach,
                   Double(reach) / Double(total) > Self.hubShare {
                    hubs.append(row["name"] as String? ?? "?")
                    continue
                }
                let entityID = row["entityID"] as Int64? ?? 0
                let attached = try Int64.fetchAll(db, sql: """
                    SELECT CAST(SUBSTR(src, 8) AS INTEGER) FROM link
                    WHERE dst = ? AND src LIKE 'record:%'
                    """, arguments: ["entity:\(entityID)"])

                for a in attached {
                    entitiesByRecord[a, default: []].insert(entityID)
                    for b in attached where a != b {
                        adjacency[a, default: [:]][b, default: 0] += 1
                    }
                }
            }
        }
        return (adjacency, entitiesByRecord, hubs)
    }

    /// Label propagation: each record repeatedly adopts the label most common among
    /// its neighbours until nothing changes. Cheap, incremental, and no need to decide
    /// in advance how many categories there should be.
    ///
    /// Ties break on the lowest id so the result is identical run to run — a category
    /// list that reshuffles for no reason would be worse than a slightly worse one.
    static func propagateLabels(over adjacency: [Int64: [Int64: Int]], records: [Int64],
                                entities: [Int64: Set<Int64>] = [:]) -> [Int64: Int] {
        var labels: [Int64: Int] = [:]
        for (index, id) in records.sorted().enumerated() { labels[id] = index }

        for _ in 0..<20 {
            var changed = false
            for id in records.sorted() {
                guard let neighbours = adjacency[id], !neighbours.isEmpty else { continue }
                var weights: [Int: Int] = [:]
                // Which *distinct* entities tie this record to each group. Summing edge
                // weights instead would count one shared name three times just because
                // the group has three members.
                var bridging: [Int: Set<Int64>] = [:]
                let mine = entities[id] ?? []

                for (neighbour, weight) in neighbours {
                    guard let label = labels[neighbour] else { continue }
                    weights[label, default: 0] += weight
                    bridging[label, default: []].formUnion(mine.intersection(entities[neighbour] ?? []))
                }
                guard let best = weights.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key
                else { continue }

                // One shared name is a coincidence, not a category. A car registration
                // and a health policy both naming the same insurer belong to different
                // parts of a life; joining on that single tie is how unrelated documents
                // get swept into a category and quietly make it untrustworthy.
                if !entities.isEmpty, (bridging[best]?.count ?? 0) < minimumAttachment { continue }
                if labels[id] != best { labels[id] = best; changed = true }
            }
            if !changed { break }
        }
        return labels
    }

    // MARK: - Naming

    /// The cluster's name is a vote. Stage 3 already asked the model what each document
    /// looked like; here those independent guesses are counted, so the graph decides
    /// membership and the model's opinions decide the label — with no extra call.
    static func name(for group: [Record]) -> String {
        let hints = group.compactMap { $0.category?.trimmed.nilIfEmpty }
            .filter { $0 != holdingCategory }
        if let winner = mostCommon(hints) { return winner }

        // No usable hints — fall back to what the documents *are*.
        if let kind = mostCommon(group.compactMap { $0.kind?.trimmed.nilIfEmpty }) {
            return kind.capitalizedFirst + "s"
        }
        return holdingCategory
    }

    /// When two clusters vote for the same name, name the second for what actually
    /// binds it together.
    static func distinguisher(for group: [Record]) -> String? {
        mostCommon(group.compactMap { $0.kind?.trimmed.nilIfEmpty }).map { $0.capitalizedFirst + "s" }
    }

    static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        // Alphabetical tie-break, again for stability across runs.
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
