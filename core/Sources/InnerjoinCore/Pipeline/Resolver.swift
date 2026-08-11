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

        // Expanding an abbreviation requires knowing what it expands to. If the stored
        // name is *itself* abbreviated, it doesn't: a node called "J. Ramirez" is exactly
        // as much Jose as Joanna, and letting it absorb either is a coin flip that
        // presents as certainty.
        //
        // Measured, not theorised. In one run the first document failed, so the library's
        // only Ramirez node was "J. Ramirez" — and Jose merged straight into Joanna. The
        // rung above can still resolve these, because an identifier or a shared context
        // is real evidence; a resemblance between two abbreviations is not.
        // The distinction is *skipping* an initial versus *expanding* one.
        // "Kian Feiz" against a stored "Kian J. Feiz" skips the middle initial and still
        // matches two whole words — safe. "Jose Ramirez" against a stored "J. Ramirez"
        // has to decide that J means Jose, on the strength of a surname — not safe, and
        // exactly as available to Joanna.
        // What rung 4 is allowed to decide on its own.
        //
        // Two exclusions, both learned from data rather than assumed.
        //
        // An *abbreviation* can't be expanded against a candidate that is itself
        // abbreviated: a node called "J. Ramirez" is exactly as much Jose as Joanna.
        // Skipping a middle initial is fine — "Kian Feiz" against "Kian J. Feiz" still
        // agrees on two whole words — so only genuine expansion is blocked.
        //
        // A *nickname* can't decide anything alone. The public table this now uses is an
        // undirected, noisy graph rather than a clean map: it lists `robert` as a short
        // form of `bill`, which would quietly merge Bill Chen with Robert Chen. Real
        // short forms are worth having — Peggy is Margaret, and no string measure will
        // ever find that — but they are evidence, not proof, so they resolve only with
        // an identifier or a shared context behind them.
        // How many people in the library could be behind this surname.
        //
        // The Fellegi-Sunter idea the ladder was missing, and it settles a question that
        // looked like a product decision: how much corroboration should a weak
        // resemblance need? Not a fixed amount. A shared "Ramirez" in a library holding
        // one Ramirez nearly identifies a person; a shared "Smith" among twelve narrows
        // almost nothing. Demanding the same evidence for both refuses the safe cases
        // along with the dangerous ones.
        //
        // Measured on FEBRL: letting a weak match stand where the surname is rare
        // recovers 21% of recall at 99% precision and wrongly merges exactly as many
        // same-surname people as refusing every weak match — seven, either way.
        // Rarity is a statistic, and a statistic over three people means nothing: in a
        // library that small *every* surname looks rare and the test licenses everything.
        // It only starts carrying information once there is a population behind it.
        let populationIsBigEnough = sameKind.count >= rarityNeedsLibraryOf
        let surname = normalized.split(separator: " ").last.map(String.init)
        let sharingSurname = surname.map { name in
            sameKind.filter {
                $0.normalized.split(separator: " ").last.map(String.init) == name
            }.count
        } ?? Int.max

        let expandable = compatible.filter { candidate in
            switch matchKind(normalized, candidate.normalized) {
            case .subsequence: return true
            case .initials:    return !isAbbreviated(candidate.normalized)
            // A resemblance proposes rather than decides — unless the surname is itself
            // rare enough that there is hardly anyone else it could be.
            case .nickname, .typo, .similar:
                return populationIsBigEnough && sharingSurname <= rareSurnameCeiling
            case .none:                      return false
            }
        }

        // 4 — compatible, and there is exactly one it could possibly be.
        //
        // The whole safety of this design sits on `count == 1`. "J. Ramirez" folds into
        // "Joanna Ramirez" only while she is the only Ramirez in the library; the day a
        // Jose Ramirez arrives, this stops firing and both mentions wait for a human
        // rather than guessing. Silence is the correct output of an ambiguous question.
        if expandable.count == 1 {
            return Outcome(entityID: expandable[0].entityID, how: .unambiguous, confidence: 0.8)
        }

        return nil
    }

    // MARK: - Name compatibility

    /// Whether two normalized names could name the same person or thing.
    ///
    /// Deliberately says *could*. This never decides anything by itself — rungs 3 and 4
    /// add the corroboration or the uniqueness that makes it safe to act on.
    public static func couldBeTheSame(_ a: String, _ b: String) -> Bool {
        matchKind(a, b) != nil
    }

    /// How two names match, which matters as much as whether they do.
    public enum MatchKind: Sendable, Equatable {
        /// Every word of one appears in the other, in order — nothing is being guessed.
        case subsequence
        /// One side abbreviates a word the other spells out, so something is.
        case initials
        /// A short form standing in for a given name. Weak: see below.
        case nickname
        /// One word misspelt, every other word identical.
        case typo
        /// Alike by graded string similarity — the measure the record-linkage literature
        /// uses. Weakest of all, and the only rung that catches corrupted names.
        case similar
    }

    public static func matchKind(_ rawA: String, _ rawB: String) -> MatchKind? {
        // Written form is normalized here rather than in `Entity.normalize`, because that
        // key indexes every table and is shared by organizations, places and products —
        // inverting "Alcon Laboratories, Inc." helps nobody. Only *person* matching cares
        // that a register writes "Braund, Mr. Owen Harris".
        let a = Entity.normalize(Entity.canonicalPersonForm(rawA))
        let b = Entity.normalize(Entity.canonicalPersonForm(rawB))
        if a == b { return .subsequence }
        let first = a.split(separator: " ").map(String.init)
        let second = b.split(separator: " ").map(String.init)
        guard !first.isEmpty, !second.isEmpty else { return nil }

        let (longer, shorter) = first.count >= second.count ? (first, second) : (second, first)
        // A single word is not enough to identify a person. "Feiz" could be any Feiz, and
        // treating a bare surname as a match is how families get merged into one person.
        guard shorter.count >= 2 || longer.count == shorter.count else { return nil }

        // Literal agreement first, so a match that needs no nickname table isn't
        // downgraded by one.
        if isSubsequence(shorter, of: longer, allowingNicknames: false) { return .subsequence }
        if initialsMatch(shorter, longer) { return .initials }
        if isSubsequence(shorter, of: longer, allowingNicknames: true) { return .nickname }
        if isTypo(first, second) { return .typo }
        // Graded similarity, last and weakest.
        //
        // Added on evidence. Measured against FEBRL — the standard public benchmark for
        // person record linkage — the ladder reached 98% precision but only 36% recall,
        // while plain Jaro-Winkler at 0.90 reached 59% at the same precision. Worse, the
        // rung allowed to decide on its own fired on *none* of it: FEBRL's errors are
        // substitutions and transpositions, not truncations or initials, so every
        // real-world corrupted name was falling through to nothing.
        //
        // It stays a proposing rung, so the discipline is unchanged — what improves is
        // how much there is to corroborate.
        return similarity(a, b) >= similarityThreshold ? .similar : nil
    }

    /// One word misspelt and the rest identical — "Marcus Web" against "Marcus Webb",
    /// "Gonzales" against "Gonzalez".
    ///
    /// This is the gap between the ladder and the published record-linkage tools. Splink,
    /// dedupe and fastLink all score names on a graded string measure (Jaro-Winkler,
    /// usually) precisely so a transposition or a dropped letter doesn't split a person in
    /// two; the ladder had no tolerance at all and would file both spellings separately.
    ///
    /// Kept deliberately tight, and kept weak. One edit in one word — because "Jon Smith"
    /// and "Jan Smith" are also one edit apart and are two people. Like a nickname it can
    /// propose but never decide, so what makes it safe is the corroboration it still has
    /// to find.
    static func isTypo(_ first: [String], _ second: [String]) -> Bool {
        guard first.count == second.count, first.count >= 2 else { return false }
        var differing: (String, String)?
        for (left, right) in zip(first, second) where left != right {
            guard differing == nil else { return false }   // two words differ: not a typo
            differing = (left, right)
        }
        guard let (left, right) = differing else { return false }
        // A word too short to misspell recognisably. Measured on the longer of the two,
        // so "web" against "webb" counts — a dropped final letter — while "jon" against
        // "jan" does not, since at three letters one edit is as likely to be a different
        // name as a slip.
        guard max(left.count, right.count) >= 4 else { return false }
        return editDistance(left, right) == 1
    }

    /// Levenshtein, bounded at two so it can stop early.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b)
        if abs(left.count - right.count) > 1 { return 2 }
        var previous = Array(0...right.count)
        for i in 1...max(1, left.count) {
            var current = [i] + Array(repeating: 0, count: right.count)
            for j in 1...max(1, right.count) where j <= right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
            if previous.min() ?? 0 > 1 { return 2 }   // already too far apart
        }
        return previous[right.count]
    }

    /// Where graded similarity starts counting as a resemblance worth checking.
    ///
    /// Chosen against FEBRL rather than by taste. The sweep, at 5,792 labelled pairs:
    ///
    ///     0.88   97% precision   61% recall   39 same-surname people wrongly merged
    ///     0.90   98%             59%          25
    ///     0.92   99%             58%          18
    ///     0.94   99%             55%          15
    ///
    /// 0.92 rather than the 0.90 the literature tends to use, because the costs here are
    /// not symmetric: a split is visible and someone fixes it, a wrong merge is silent and
    /// poisons every answer about both people. One point of recall for seven fewer of
    /// those is the right way round. `ijeval --linkage` re-runs the sweep.
    public static let similarityThreshold = 0.92

    /// Jaro-Winkler: the measure Splink, dedupe and fastLink all use for a name field.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let first = Array(a), second = Array(b)
        if first.isEmpty || second.isEmpty { return first == second ? 1 : 0 }
        if first == second { return 1 }

        let window = max(0, max(first.count, second.count) / 2 - 1)
        var firstMatched = [Bool](repeating: false, count: first.count)
        var secondMatched = [Bool](repeating: false, count: second.count)
        var matches = 0

        for i in first.indices {
            let low = max(0, i - window), high = min(second.count - 1, i + window)
            guard low <= high else { continue }
            for j in low...high where !secondMatched[j] && first[i] == second[j] {
                firstMatched[i] = true; secondMatched[j] = true; matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0, k = 0
        for i in first.indices where firstMatched[i] {
            while k < secondMatched.count && !secondMatched[k] { k += 1 }
            guard k < second.count else { break }
            if first[i] != second[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(first.count) + m / Double(second.count)
                    + (m - Double(transpositions) / 2) / m) / 3

        var prefix = 0
        for (x, y) in zip(first, second) {
            if x != y { break }
            prefix += 1
            if prefix == 4 { break }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    /// How many people may share a surname before it stops narrowing anything.
    /// Three, from the FEBRL sweep: at that ceiling precision holds at 99% and the
    /// wrong-merge count doesn't move at all.
    public static let rareSurnameCeiling = 3

    /// How many people the library needs before "this surname is rare" says anything.
    /// Below it, a weak resemblance still needs corroboration.
    public static let rarityNeedsLibraryOf = 12

    /// Whether a name is itself an abbreviation — carries a bare initial where a word
    /// belongs. Such a name identifies a person only once you already know who they are.
    public static func isAbbreviated(_ normalized: String) -> Bool {
        normalized.split(separator: " ").contains { $0.count == 1 }
    }

    /// Every word of the shorter name appearing in the longer one, in order.
    ///
    /// This is the fix for the bug that started all of this. The old rule tested whether
    /// the short name was a *prefix* of the long one, which handles truncation
    /// ("Alcon" ← "Alcon Laboratories") but not insertion — and a middle initial is an
    /// insertion, so "Kian Feiz" and "Kian J. Feiz" became two people.
    static func isSubsequence(_ shorter: [String], of longer: [String],
                              allowingNicknames: Bool = true) -> Bool {
        var index = 0
        for word in longer where index < shorter.count {
            let same = allowingNicknames
                ? equivalent(word, shorter[index])
                : word == shorter[index]
            if same { index += 1 }
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

    /// Two name words meaning the same thing — the same word, or a short form standing
    /// for it.
    ///
    /// Deliberately one-directional. "Bob" and "Bert" are both short for Robert, and
    /// letting two nicknames match through their shared formal name would make them the
    /// same person. A nickname expands to what it stands for; it never expands sideways.
    static func equivalent(_ a: String, _ b: String) -> Bool {
        a == b || Nicknames.stands(a, for: b) || Nicknames.stands(b, for: a)
    }

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
