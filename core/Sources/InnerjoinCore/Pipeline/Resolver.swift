import Foundation
import GRDB

/// Decides which person a name refers to.
///
/// A ladder, cheapest and most certain first. A mention resolves at the first rung that
/// fires and records which one, so a wrong merge can always be traced back to the rule
/// that made it.
///
/// The rung that matters most is the last one. Most entity systems merge greedily and
/// quietly corrupt themselves — two people called Ramirez become one, and nothing ever
/// tells you. So the rule here is: **when more than one candidate fits, refuse.** An
/// unresolved mention is a small, visible, fixable problem. A wrong merge is an invisible
/// one that poisons every answer downstream.
///
/// Entirely deterministic. No model call, so resolution is free and runs whenever.
public enum Resolver {

    /// A name that could be the one we're looking at.
    public struct Candidate: Sendable {
        public let entityID: Int64
        public let name: String
        public let normalized: String
        public let kind: Entity.Kind
        /// Identifiers already known for this identity — an email or a phone number.
        public let identifiers: Set<String>
        /// Other identities this one is already known to appear alongside.
        public let context: Set<Int64>

        public init(entityID: Int64, name: String, kind: Entity.Kind,
                    identifiers: Set<String> = [], context: Set<Int64> = []) {
            self.entityID = entityID
            self.name = name
            self.normalized = Entity.normalize(name)
            self.kind = kind
            self.identifiers = identifiers
            self.context = context
        }
    }

    public struct Outcome: Sendable {
        public let entityID: Int64
        public let how: Mention.Resolution
        public let confidence: Double
    }

    /// Which identity this mention belongs to, or nil when it genuinely can't be told.
    ///
    /// - `identifiers`: emails and phone numbers found in the *same document*, which is
    ///   what lets "J. Ramirez" resolve by her address rather than her spelling.
    /// - `alongside`: other identities named in the same document.
    public static func resolve(
        surface: String,
        kind: Entity.Kind,
        identifiers: Set<String> = [],
        alongside: Set<Int64> = [],
        among candidates: [Candidate]
    ) -> Outcome? {
        let normalized = Entity.normalize(surface)
        guard !normalized.isEmpty else { return nil }

        // 1 — the same name, whatever kind it was labelled.
        //
        // Kind-blind on purpose, and it was measured: a model calls one organization
        // `org` on the first document, `place` on the second and `person` on the third,
        // and matching on kind minted a node for each — so documents that should have
        // clustered together didn't, and a third of the library sat unfiled. The cost is
        // that a founder can merge with the company named after them; the benefit is a
        // graph that connects at all.
        if let exact = candidates.first(where: { $0.normalized == normalized }) {
            return Outcome(entityID: exact.entityID, how: .exact, confidence: 1.0)
        }

        // The looser rungs below stay within a kind. An exact name is strong enough to
        // override a wrong label; a *resemblance* across kinds is just a guess on top of
        // a guess.
        let sameKind = candidates.filter { $0.kind == kind }

        // 2 — a shared identifier. An email address is a globally unique key for a
        // person, so this outranks every spelling question: two mentions sharing
        // joanna@acme.com are the same person however her name was typed.
        if !identifiers.isEmpty {
            let byIdentifier = sameKind.filter { !$0.identifiers.isDisjoint(with: identifiers) }
            if byIdentifier.count == 1 {
                return Outcome(entityID: byIdentifier[0].entityID, how: .identifier, confidence: 1.0)
            }
        }

        // Everything below needs the names to at least be compatible.
        let compatible = sameKind.filter { couldBeTheSame(normalized, $0.normalized) }
        guard !compatible.isEmpty else { return nil }

        // 3 — compatible, and it already knows someone else in this document. Two
        // corroborating signals, so this is allowed to pick between several candidates.
        let corroborated = compatible.filter { !$0.context.isDisjoint(with: alongside) }
        if corroborated.count == 1 {
            return Outcome(entityID: corroborated[0].entityID, how: .context, confidence: 0.9)
        }

        // 4 — compatible, and there is exactly one it could possibly be.
        //
        // The whole safety of this design sits on `count == 1`. "J. Ramirez" folds into
        // "Joanna Ramirez" only while she is the only Ramirez in the library; the day a
        // Jose Ramirez arrives, this stops firing and both mentions wait for a human
        // rather than guessing. Silence is the correct output of an ambiguous question.
        if compatible.count == 1 {
            return Outcome(entityID: compatible[0].entityID, how: .unambiguous, confidence: 0.8)
        }

        return nil
    }

    // MARK: - Name compatibility

    /// Whether two normalized names could name the same person or thing.
    ///
    /// Deliberately says *could*. This never decides anything by itself — rungs 3 and 4
    /// add the corroboration or the uniqueness that makes it safe to act on.
    public static func couldBeTheSame(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let first = a.split(separator: " ").map(String.init)
        let second = b.split(separator: " ").map(String.init)
        guard !first.isEmpty, !second.isEmpty else { return false }

        let (longer, shorter) = first.count >= second.count ? (first, second) : (second, first)
        // A single word is not enough to identify a person. "Feiz" could be any Feiz, and
        // treating a bare surname as a match is how families get merged into one person.
        guard shorter.count >= 2 || longer.count == shorter.count else { return false }

        return isSubsequence(shorter, of: longer) || initialsMatch(shorter, longer)
    }

    /// Every word of the shorter name appearing in the longer one, in order.
    ///
    /// This is the fix for the bug that started all of this. The old rule tested whether
    /// the short name was a *prefix* of the long one, which handles truncation
    /// ("Alcon" ← "Alcon Laboratories") but not insertion — and a middle initial is an
    /// insertion, so "Kian Feiz" and "Kian J. Feiz" became two people.
    static func isSubsequence(_ shorter: [String], of longer: [String]) -> Bool {
        var index = 0
        for word in longer where index < shorter.count {
            if equivalent(word, shorter[index]) { index += 1 }
        }
        return index == shorter.count
    }

    /// "j ramirez" against "joanna ramirez": the surname must match outright and the
    /// initial must begin the given name. An initial is weak evidence on its own, which
    /// is exactly why it only ever reaches rung 3 or 4.
    static func initialsMatch(_ shorter: [String], _ longer: [String]) -> Bool {
        guard shorter.count == longer.count, shorter.count >= 2 else { return false }
        var sawInitial = false
        for (short, long) in zip(shorter, longer) {
            if equivalent(short, long) { continue }
            if short.count == 1, long.hasPrefix(short) { sawInitial = true; continue }
            if long.count == 1, short.hasPrefix(long) { sawInitial = true; continue }
            return false
        }
        return sawInitial
    }

    /// Two name words meaning the same thing — the same word, or a known short form.
    static func equivalent(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if let full = nicknames[a], full == b { return true }
        if let full = nicknames[b], full == a { return true }
        return false
    }

    /// Short forms common enough that a document will use one and a signature the other.
    /// Small on purpose: a long list starts merging people who merely share a nickname.
    static let nicknames: [String: String] = [
        "bob": "robert", "rob": "robert", "bobby": "robert",
        "bill": "william", "will": "william", "billy": "william",
        "jo": "joanna", "joann": "joanna", "jo anna": "joanna",
        "kate": "katherine", "katie": "katherine", "cathy": "catherine",
        "mike": "michael", "mick": "michael",
        "dave": "david", "jim": "james", "jimmy": "james",
        "tom": "thomas", "tony": "anthony", "chris": "christopher",
        "dan": "daniel", "danny": "daniel", "matt": "matthew",
        "nick": "nicholas", "sam": "samuel", "steve": "stephen",
        "ben": "benjamin", "alex": "alexander", "andy": "andrew",
        "liz": "elizabeth", "beth": "elizabeth", "sue": "susan",
        "peggy": "margaret", "meg": "margaret", "maggie": "margaret",
    ]

    // MARK: - Identifiers

    /// Emails and phone numbers in a document, normalized so two spellings of one number
    /// compare equal.
    ///
    /// These are the strongest identity signal available and they were being thrown away:
    /// the readers already surface them, and nothing used them to tell people apart.
    public static func identifiers(in text: String) -> Set<String> {
        var found: Set<String> = []

        let emails = matches(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: text)
        for email in emails { found.insert("email:" + email.lowercased()) }

        // Ten or more digits, however the document chose to punctuate them.
        for candidate in matches(#"(?:\+?\d[\d\s().-]{8,}\d)"#, in: text) {
            let digits = candidate.filter(\.isNumber)
            guard digits.count >= 10 else { continue }
            // Compare on the last ten, so a country code doesn't split one number in two.
            found.insert("phone:" + String(digits.suffix(10)))
        }
        return found
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
