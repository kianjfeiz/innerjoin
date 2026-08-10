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
    /// Set at 0.35, lowered from 0.6 after real runs. The original worry was that a
    /// library splitting into two halves gives each defining entity 50%, so a strict
    /// threshold would discard the structure — but measured on a real library the
    /// defining entities sit at 20–25% (one vendor, one landlord, one clinic) while the
    /// owner's own name reaches 36%. The gap is wide enough to cut between.
    ///
    /// This backs up the spread test below rather than replacing it, because that test
    /// reads the model's category guesses — and on the run where those guesses all came
    /// back the same word, it saw no spread, suppressed nothing, and the whole library
    /// collapsed into one category. A rule that fails exactly when the signal it depends
    /// on fails needs a second rule that doesn't.
    public static let hubShare = 0.6

    /// The share above which an entity stops being informative, which depends on how
    /// much library there is.
    ///
    /// In a small library a group's defining entity legitimately reaches a high share —
    /// six documents in two groups puts each group's entity at 50% — so a strict
    /// threshold there deletes the structure instead of the noise, and there is little
    /// to cluster anyway. Once there are enough documents for a few real groups, the gap
    /// opens up: measured on a twenty-five document library the defining entities sat at
    /// 20–25% (one vendor, one landlord, one clinic) while the owner's own name reached
    /// 36%. That gap is what this cuts between.
    static let largeLibrary = 20
    static let hubShareWhenLarge = 0.35

    static func hubShare(forLibraryOf total: Int) -> Double {
        total >= largeLibrary ? hubShareWhenLarge : hubShare
    }

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
    public func neighbours(of records: [Record]) throws
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
                let entityID = row["entityID"] as Int64? ?? 0
                let attached = try Int64.fetchAll(db, sql: """
                    SELECT CAST(SUBSTR(src, 8) AS INTEGER) FROM link
                    WHERE dst = ? AND src LIKE 'record:%'
                    """, arguments: ["entity:\(entityID)"])

                if total >= Self.hubMinimumRecords, reach >= Self.hubMinimumReach {
                    // Reach alone, deliberately.
                    //
                    // I also tried a spread test: an entity whose documents were guessed
                    // into three or more different areas of life is the person
                    // themselves, not a subject. It reads well and it measured badly. On
                    // one run it saw no spread at all — the model had labelled everything
                    // with the same word — suppressed nothing, and the library collapsed
                    // into one category. On the next it suppressed the landlord, whose
                    // six documents had been guessed as Apartment, Utilities and
                    // Finance, and took the Apartment cluster down with him. The test
                    // was reading the model's naming consistency and calling it
                    // structure. Reach doesn't depend on that, and across runs it picks
                    // out the owner (36–40% of the library) while leaving the landlord
                    // (20–28%) alone.
                    if Double(reach) / Double(total) > Self.hubShare(forLibraryOf: total) {
                        hubs.append(row["name"] as String? ?? "?")
                        continue
                    }
                }

                // Weight by rarity, not by count. Two documents that share a landlord
                // who appears on six of them are less related than two that share a
                // clinic appearing on three — the same reasoning that makes hub
                // suppression necessary, applied by degree instead of as a cliff edge.
                // Suppression can only delete an entity or keep it whole; this lets a
                // moderately common name still count for something, just less, which is
                // what stops one borderline entity from deciding the whole shape.
                let weight = max(1, 1_000 / reach)
                for a in attached {
                    entitiesByRecord[a, default: []].insert(entityID)
                    for b in attached where a != b {
                        adjacency[a, default: [:]][b, default: 0] += weight
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
        // The model's own reading, never our previous conclusion.
        let hints = group.compactMap { ($0.categoryHint ?? $0.category)?.trimmed.nilIfEmpty }
            .filter { $0 != holdingCategory }

        // A vote of one isn't a vote. A real run named a cluster of thirteen documents
        // "spending_report" because a single spreadsheet said so and nothing else
        // agreed — one document's opinion became the name of most of the library.
        // Above a handful of members, a name has to be seconded.
        let needsSeconding = group.count >= 3
        if let winner = mostCommon(hints),
           !needsSeconding || hints.filter({ $0 == winner }).count >= 2 {
            return winner
        }

        // No agreement — fall back to what the documents *are*, under the same rule.
        let kinds = group.compactMap { $0.kind?.trimmed.nilIfEmpty }
        if let kind = mostCommon(kinds),
           !needsSeconding || kinds.filter({ $0 == kind }).count >= 2 {
            return kind.capitalizedFirst + "s"
        }
        // Better an honest holding pen than a confident wrong shelf.
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
