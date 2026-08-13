import Foundation
import GRDB

/// What the library knows about a person, and how it decides what's still true.
///
/// Two jobs, both small. **Admitting** claims — a gate as strict as the one for entities,
/// because a memory that accumulates junk about people is worse than one that stays
/// empty. And **reading them back** as a profile, where the newest document wins and the
/// older ones become history rather than contradictions.
public struct Memory: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    // MARK: - Admitting

    /// Records what a document claims about the people it names.
    ///
    /// Refused, in order of how often it happens: a subject who isn't an admitted entity
    /// (the model asserting about scenery), a predicate outside the list, an object that
    /// doesn't appear in the document, and a value too long to be a fact rather than a
    /// sentence.
    @discardableResult
    func record(_ proposed: [Reply.ProposedAssertion],
                       subjects: [String: Int64],
                       documentID: Int64,
                       documentText: String,
                       on date: Date?,
                       anchors: (String?) -> String?) async throws -> (kept: Int, refused: [String]) {
        var refused: [String] = []
        var admitted: [Assertion] = []

        for claim in proposed {
            let subjectName = claim.subject.trimmed
            guard let subjectID = subjects[Entity.normalize(subjectName)] else {
                refused.append("\(subjectName) (not an entity of this document)")
                continue
            }
            guard let predicate = Assertion.Predicate(rawValue: claim.predicate.trimmed.lowercased()) else {
                refused.append("\(subjectName) \(claim.predicate) (unknown predicate)")
                continue
            }
            let object = claim.object.trimmed
            guard !object.isEmpty, object.count <= 120 else {
                refused.append("\(subjectName) \(claim.predicate) (object missing or too long)")
                continue
            }
            // The document has to actually say it. Same rule as the entity gate, and it
            // catches the same failure: a model filling in what it assumes rather than
            // what it read.
            guard Self.appears(object, in: documentText) else {
                refused.append("\(subjectName) \(claim.predicate) \(object) (not in the document)")
                continue
            }

            var objectEntityID: Int64?
            var objectValue: String?
            if predicate.takesEntity {
                // The object of `works_at` is a company, and a company we already know
                // about. If it isn't one, the claim is about something unverified.
                guard let id = subjects[Entity.normalize(object)] else {
                    refused.append("\(subjectName) \(claim.predicate) \(object) (object isn't a known entity)")
                    continue
                }
                guard id != subjectID else {
                    refused.append("\(subjectName) \(claim.predicate) itself")
                    continue
                }
                objectEntityID = id
            } else {
                objectValue = predicate == .email || predicate == .phone
                    ? object.lowercased() : object
            }

            admitted.append(Assertion(
                subjectID: subjectID, predicate: predicate,
                objectEntityID: objectEntityID, objectValue: objectValue,
                documentID: documentID, elementTag: anchors(claim.source),
                assertedOn: date,
                since: Dates.parse(claim.since), until: Dates.parse(claim.until)))
        }

        let rows = admitted
        try await store.dbQueue.write { db in
            // Re-reading a document replaces what it claimed rather than piling up.
            try db.execute(sql: "DELETE FROM assertion WHERE documentID = ?", arguments: [documentID])
            for var assertion in rows { try? assertion.insert(db) }
        }
        return (rows.count, refused)
    }

    /// Whether the document says this, allowing for the punctuation drifting.
    static func appears(_ value: String, in text: String) -> Bool {
        if text.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        let loose = { (string: String) in
            string.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let needle = loose(value)
        guard needle.count >= 3 else { return false }
        return loose(text).contains(needle)
    }

    // MARK: - Reading back

    /// Everything known about one identity, with the current answers first.
    public struct Profile: Sendable {
        public let entity: Entity
        public let documentCount: Int
        public let firstSeen: Date?
        public let lastSeen: Date?
        /// Spellings this identity has appeared under, other than its own name.
        public let alsoKnownAs: [String]
        /// One entry per predicate: what's true now, and what it replaced.
        public let facts: [Fact]

        public struct Fact: Sendable {
            public let predicate: Assertion.Predicate
            public let value: String
            public let since: Date?
            public let documentID: Int64?
            public let elementTag: String?
            /// Earlier answers to the same question, newest first. People change jobs;
            /// a profile that hides that is a profile that will one day be wrong.
            public let previously: [(value: String, on: Date?)]
        }
    }

    public func profile(of entityID: Int64) throws -> Profile? {
        guard let entity = try store.entity(id: entityID) else { return nil }

        let mentions = try store.mentions(of: entityID)
        let documents = Set(mentions.map(\.documentID))
        let alsoKnownAs = Array(Set(mentions.map(\.surface))
            .subtracting([entity.name])).sorted()

        let assertions = try store.assertions(about: entityID)
        var byPredicate: [Assertion.Predicate: [Assertion]] = [:]
        for assertion in assertions { byPredicate[assertion.predicate, default: []].append(assertion) }

        var facts: [Profile.Fact] = []
        for (predicate, group) in byPredicate {
            // A fact the document says has *ended* can never be the current answer,
            // however recently it was stated — a résumé lists three jobs and two of them
            // are over. Among the ones still standing, the latest start wins; an undated
            // claim can't overrule a dated one, so it sorts last rather than by accident.
            let ordered = group.sorted { left, right in
                if left.isCurrent != right.isCurrent { return left.isCurrent }
                return (left.effectiveDate ?? .distantPast) > (right.effectiveDate ?? .distantPast)
            }
            guard let current = ordered.first else { continue }
            let value = try self.text(of: current)

            // Only genuinely different answers count as history. Five documents all
            // saying "Acme" is one fact, not five.
            var seen: Set<String> = [value.lowercased()]
            var previously: [(String, Date?)] = []
            for older in ordered.dropFirst() {
                let text = try self.text(of: older)
                guard !seen.contains(text.lowercased()) else { continue }
                seen.insert(text.lowercased())
                previously.append((text, older.until ?? older.effectiveDate))
            }

            facts.append(Profile.Fact(
                predicate: predicate, value: value, since: current.since ?? current.assertedOn,
                documentID: current.documentID, elementTag: current.elementTag,
                previously: previously))
        }
        // Stable order, so a profile looks the same twice.
        facts.sort { $0.predicate.rawValue < $1.predicate.rawValue }

        return Profile(entity: entity, documentCount: documents.count,
                       firstSeen: entity.firstSeenOn, lastSeen: entity.lastSeenOn,
                       alsoKnownAs: alsoKnownAs, facts: facts)
    }

    private func text(of assertion: Assertion) throws -> String {
        if let objectID = assertion.objectEntityID {
            return try store.entity(id: objectID)?.label ?? "—"
        }
        return assertion.objectValue ?? "—"
    }

    /// Stamps each identity with the dates of the earliest and latest documents it
    /// appears in — its own dates, not when we happened to read them. "Known since March
    /// 2024" is a fact about the person; "added on Tuesday" is a fact about us.
    @discardableResult
    public func refreshSeenDates() async throws -> Int {
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE entity SET
                  firstSeenOn = (
                    SELECT MIN(COALESCE(r.happenedOn, d.createdAt, d.addedAt))
                    FROM mention m
                    JOIN document d ON d.id = m.documentID
                    LEFT JOIN record r ON r.documentID = m.documentID
                    WHERE m.entityID = entity.id),
                  lastSeenOn = (
                    SELECT MAX(COALESCE(r.happenedOn, d.createdAt, d.addedAt))
                    FROM mention m
                    JOIN document d ON d.id = m.documentID
                    LEFT JOIN record r ON r.documentID = m.documentID
                    WHERE m.entityID = entity.id)
                WHERE EXISTS (SELECT 1 FROM mention WHERE entityID = entity.id)
                """)
            return db.changesCount
        }
    }
}
