import Foundation
import DunesCore

/// A corpus built to break identity resolution specifically.
///
/// The main corpus measures whether documents are *read* correctly. This one measures
/// whether the people in them are *the same people* — which is a different failure and,
/// until now, an unmeasured one. Every document here exists to make one mistake possible:
///
/// - the same person under four spellings, so a miss shows up as a split
/// - two people who share a surname, so a greedy matcher shows up as a wrong merge
/// - a nickname, which no string-similarity measure will ever catch
/// - a job change, so "where do they work" has a right and a wrong answer
/// - a relation per document, so `mentions` for everything scores as the failure it is
enum PeopleCorpus {

    struct ExpectedPerson {
        let canonical: String
        /// Every way this person is written across the corpus.
        let surfaces: [String]
        /// Who they must never be merged with.
        let distinctFrom: [String]
        /// Where they work as of the most recent document that says.
        let currentEmployer: String?
        /// What they used to be, which must appear as history rather than vanish.
        let formerEmployer: String?
    }

    /// A relationship a document states, which the graph should record as more than
    /// "these names appeared near each other".
    struct ExpectedRelation {
        let file: String
        let entity: String
        let relation: String
    }

    static let people: [ExpectedPerson] = [
        ExpectedPerson(canonical: "Joanna Ramirez",
                       surfaces: ["Joanna Ramirez", "J. Ramirez", "Joanna R.", "Jo Ramirez"],
                       distinctFrom: ["Jose Ramirez"],
                       currentEmployer: "Acme Corporation",
                       formerEmployer: "Globex Industries"),
        ExpectedPerson(canonical: "Jose Ramirez",
                       surfaces: ["Jose Ramirez"],
                       distinctFrom: ["Joanna Ramirez"],
                       currentEmployer: "Northwind Freight",
                       formerEmployer: nil),
        ExpectedPerson(canonical: "Robert Chen",
                       surfaces: ["Robert Chen", "Bob Chen"],
                       distinctFrom: [],
                       currentEmployer: nil,
                       formerEmployer: nil),
    ]

    static let relations: [ExpectedRelation] = [
        ExpectedRelation(file: "globex_offer.md", entity: "Globex Industries", relation: "employed_by"),
        ExpectedRelation(file: "acme_offer.md", entity: "Acme Corporation", relation: "employed_by"),
        ExpectedRelation(file: "ramirez_invoice.md", entity: "Acme Corporation", relation: "issued_by"),
        ExpectedRelation(file: "chen_lease.md", entity: "Robert Chen", relation: "party_to"),
    ]

    /// Writes the corpus. Deliberately ordered so the hard case comes *after* the easy
    /// one: Joanna is established first, then Jose arrives and makes "J. Ramirez"
    /// ambiguous. A resolver that merges on first sight passes the first half and fails
    /// the second.
    @discardableResult
    static func build(in folder: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [String] = []

        func write(_ name: String, _ text: String) throws {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            written.append(name)
        }

        // 1 — her full name, her first employer, her address.
        try write("globex_offer.md", """
            # Offer of Employment

            Date: 2024-03-01

            Dear Joanna Ramirez,

            Globex Industries is pleased to offer you the position of Operations Analyst,
            beginning 2024-03-18. Please confirm at joanna.ramirez@globex.example.

            Sincerely,
            Globex Industries, Human Resources
            """)

        // 2 — the same person, an initial, and the same email address. The identifier
        // rung should carry this even if the name rungs don't.
        try write("ramirez_invoice.md", """
            # Invoice AC-1042

            Date of invoice: 2025-09-14
            Issued by Acme Corporation
            Attention: J. Ramirez, joanna.ramirez@globex.example

            Consulting services, September 2025 — 2,400.00
            """)

        // 3 — a job change. The newer document has to win, and the older one has to
        // survive as history rather than disappear.
        try write("acme_offer.md", """
            # Employment Agreement

            Date: 2025-07-01

            Joanna R. accepts the role of Operations Lead at Acme Corporation,
            effective 2025-07-01, having left Globex Industries on 2025-06-30.
            """)

        // 4 — an informal short form nothing string-based will catch.
        try write("team_note.md", """
            # Notes

            Date: 2025-11-02

            Jo Ramirez confirmed the Acme Corporation renewal terms.
            """)

        // 5 — the trap. A different person, same surname. After this exists, an
        // ambiguous "J. Ramirez" must resolve to nobody rather than to a coin flip.
        try write("northwind_letter.md", """
            # Letter of Engagement

            Date: 2025-04-11

            Jose Ramirez, of Northwind Freight, will act as the shipping coordinator.
            Contact: jose@northwind.example
            """)

        // 6 and 7 — a nickname across two documents.
        try write("chen_lease.md", """
            # Residential Lease

            Date: 2025-01-15

            This lease is entered into by Robert Chen, as lessor, for the property at
            88 Alder Street.
            """)
        try write("chen_note.md", """
            # Maintenance Note

            Date: 2025-08-20

            Bob Chen approved the boiler replacement at 88 Alder Street.
            """)

        return written
    }

    // MARK: - Scoring

    struct Score {
        var surfacesExpected = 0, surfacesResolved = 0
        var wrongMerges: [String] = []
        var employersExpected = 0, employersCorrect = 0
        var historyExpected = 0, historyKept = 0
        var relationsExpected = 0, relationsCorrect = 0
        var relationDetail: [String] = []
        var unresolved = 0
        var splits: [String] = []

        var personRecall: Double { ratio(surfacesResolved, surfacesExpected) }
        var employerAccuracy: Double { ratio(employersCorrect, employersExpected) }
        var relationAccuracy: Double { ratio(relationsCorrect, relationsExpected) }
        var historyAccuracy: Double { ratio(historyKept, historyExpected) }

        private func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 1 : Double(a) / Double(b) }

        /// A wrong merge is disqualifying at any rate. Two people fused into one is
        /// invisible to the user and poisons every answer about either of them, where a
        /// split is merely untidy and obvious.
        var passed: Bool {
            wrongMerges.isEmpty && personRecall >= 0.85 && relationAccuracy >= 0.70
        }

        func print() {
            let percent = { (v: Double) in String(format: "%3.0f%%", v * 100) }
            Swift.print("\n── identity ────────────────────────────────────────────")
            Swift.print("  person recall       \(percent(personRecall))   \(surfacesResolved)/\(surfacesExpected) spellings on the right person")
            Swift.print("  wrong merges        \(wrongMerges.isEmpty ? "  0" : " \(wrongMerges.count)")   \(wrongMerges.joined(separator: ", "))")
            Swift.print("  current employer    \(percent(employerAccuracy))   \(employersCorrect)/\(employersExpected)")
            Swift.print("  history kept        \(percent(historyAccuracy))   \(historyKept)/\(historyExpected)")
            Swift.print("  relations correct   \(percent(relationAccuracy))   \(relationsCorrect)/\(relationsExpected)")
            Swift.print("  unresolved mentions \(unresolved)")
            for line in splits.prefix(6)         { Swift.print("    split:    \(line)") }
            for line in relationDetail.prefix(8) { Swift.print("    relation: \(line)") }
            Swift.print("  → \(passed ? "meets thresholds" : "BELOW THRESHOLD")")
        }
    }

    static func score(store: Store) throws -> Score {
        var score = Score()
        let entities = try store.entities(limit: 500)

        // Which identity each spelling ended up on.
        var identityOfSurface: [String: Int64] = [:]
        for entity in entities {
            guard let id = entity.id else { continue }
            for mention in try store.mentions(of: id) {
                identityOfSurface[mention.surface.lowercased()] = id
            }
        }
        let unresolved = try store.unresolvedMentions()
        score.unresolved = unresolved.count

        for person in people {
            score.surfacesExpected += person.surfaces.count
            let landed = person.surfaces.compactMap { identityOfSurface[$0.lowercased()] }
            // The identity most of their spellings agree on is "them".
            let counts = Dictionary(grouping: landed, by: { $0 }).mapValues(\.count)
            guard let (theirs, agreeing) = counts.max(by: { $0.value < $1.value }) else {
                score.splits.append("\(person.canonical): none of \(person.surfaces.count) spellings resolved")
                continue
            }
            score.surfacesResolved += agreeing
            if agreeing < person.surfaces.count {
                let missing = person.surfaces.filter { identityOfSurface[$0.lowercased()] != theirs }
                score.splits.append("\(person.canonical): \(missing.joined(separator: ", ")) landed elsewhere")
            }

            // The failure that matters. Anyone they must stay apart from, who ended up
            // on the same node.
            for other in person.distinctFrom {
                if let otherID = identityOfSurface[other.lowercased()], otherID == theirs {
                    score.wrongMerges.append("\(person.canonical) + \(other)")
                }
            }

            // What the profile says they do now, and what it remembers they did before.
            guard let profile = try Memory(store: store).profile(of: theirs) else { continue }
            if let expected = person.currentEmployer {
                score.employersExpected += 1
                let current = profile.facts.first { $0.predicate == .worksAt }
                if let current, current.value.localizedCaseInsensitiveContains(
                    expected.split(separator: " ").first.map(String.init) ?? expected) {
                    score.employersCorrect += 1
                } else {
                    score.splits.append("\(person.canonical): works_at is \(current?.value ?? "unknown"), expected \(expected)")
                }
            }
            if let former = person.formerEmployer {
                score.historyExpected += 1
                let remembered = profile.facts
                    .first { $0.predicate == .worksAt }?
                    .previously.contains { $0.value.localizedCaseInsensitiveContains(
                        former.split(separator: " ").first.map(String.init) ?? former) } ?? false
                if remembered { score.historyKept += 1 }
            }
        }

        // Relations: is the lessor recorded as a party, or just as a name that appeared?
        for expected in relations {
            score.relationsExpected += 1
            guard let document = try store.allDocuments().first(where: { $0.name == expected.file }),
                  let documentID = document.id,
                  let record = try store.record(ofDocument: documentID),
                  let recordID = record.id else {
                score.relationDetail.append("\(expected.file): no record")
                continue
            }
            let parties = try store.parties(ofRecord: recordID)
            let match = parties.first {
                $0.name.localizedCaseInsensitiveContains(
                    expected.entity.split(separator: " ").first.map(String.init) ?? expected.entity)
            }
            if match?.relation == expected.relation {
                score.relationsCorrect += 1
            } else {
                score.relationDetail.append(
                    "\(expected.file): \(expected.entity) is \(match?.relation ?? "absent"), expected \(expected.relation)")
            }
        }
        return score
    }
}
