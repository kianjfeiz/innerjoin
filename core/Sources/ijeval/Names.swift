import Foundation
import InnerjoinCore

/// Scores name matching against real names from every naming system, not just the
/// Anglo-American one every string matcher is tuned on.
///
/// The corpora are drawn from Wikidata, so the truth is real rather than invented: two
/// rows with different Q-numbers are different people, and an `altLabel` is a name the
/// same person is genuinely known by. Both are downloaded as *data* — they are compared
/// as strings and printed, never interpreted.
///
/// Two numbers, measured separately because they trade against each other:
///
///   precision — how often the ladder fuzzily merges two people who are not the same.
///               Exact-name collisions are excluded: three different Diego Velázquezes
///               is an ambiguity the context rungs exist to settle, not a string bug.
///   recall    — how many real alternate spellings it reaches.
///
/// Recall is reported twice, and the split is the honest part. Wikidata's aliases include
/// epithets — "American Cincinnatus" for George Washington, "Madge" for Madonna — which
/// share no substring with the name and which *no* string algorithm can ever reach. The
/// second number covers only aliases sharing a name token, and that one is the number a
/// change to the matcher can actually move.
enum Names {
    struct Score {
        var comparisons = 0
        var proposed = 0
        var decided = 0
        var examples: [String] = []
        var rate: Double { comparisons == 0 ? 0 : Double(decided) / Double(comparisons) * 10_000 }
    }

    /// What the ladder would merge *on the strength of the names alone* — rung 4, with no
    /// shared context and no identifier behind it.
    ///
    /// This is the number that matters. A weak resemblance that merely proposes a merge
    /// and then waits for corroboration has cost nothing; only a match allowed to decide
    /// by itself can silently join two people. Measuring proposals instead would count
    /// the ladder's caution as failure.
    static func decidesAlone(_ a: String, _ b: String) -> Bool {
        switch Resolver.matchKind(a, b) {
        case .subsequence: return !Resolver.initialsDisagree(a, b)
        case .initials:    return !Resolver.isAbbreviated(Entity.normalize(b))
        // The weak rungs reach rung 4 only where the surname is rare, which is a fact
        // about a library rather than about a pair. Counted as deciding, so the number
        // stays the pessimistic one.
        // A bare surname proposes and never decides, so it can't merge anyone alone.
        case .surname:                   return false
        case .nickname, .typo, .similar: return true
        case .none:        return false
        }
    }

    static func run(distinctAt: String, variantsAt: String) throws {
        try precision(at: distinctAt)
        try recall(at: variantsAt)
    }

    // MARK: - Different people must not merge

    static func precision(at path: String) throws {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("No name corpus at \(path)."); return
        }
        var groups: [String: [(String, String)]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 3 else { continue }
            groups[String(parts[0]), default: []].append((String(parts[1]), String(parts[2])))
        }

        print("── names · different people must stay apart " + String(repeating: "─", count: 18))
        print("  drawn from Wikidata; a differing Q-number is a genuinely different person\n")
        print("  \(pad("system", 12))\(pad("people", 8))\(pad("pairs", 10))"
              + "\(pad("proposed", 10))\(pad("merged", 8))per 10k")

        var overall = Score()
        var worst: [(String, Score)] = []
        for (system, people) in groups.sorted(by: { $0.key < $1.key }) {
            var score = Score()
            for i in people.indices {
                for j in people.indices where j > i {
                    // Same person listed twice under one Q-number is not a pair.
                    guard people[i].0 != people[j].0 else { continue }
                    let a = Entity.normalize(people[i].1), b = Entity.normalize(people[j].1)
                    // An exact collision is real-world ambiguity, not a matcher error.
                    guard a != b else { continue }
                    score.comparisons += 1
                    guard Resolver.matchKind(people[i].1, people[j].1) != nil else { continue }
                    score.proposed += 1
                    if decidesAlone(people[i].1, people[j].1) {
                        score.decided += 1
                        if score.examples.count < 4 {
                            let rung = Resolver.matchKind(people[i].1, people[j].1)
                                .map { "\($0)" } ?? "?"
                            score.examples.append(
                                "\(pad(rung, 13))\(people[i].1)  ≠  \(people[j].1)")
                        }
                    }
                }
            }
            overall.comparisons += score.comparisons
            overall.proposed += score.proposed
            overall.decided += score.decided
            worst.append((system, score))
            print("  \(pad(system, 12))\(pad("\(people.count)", 8))\(pad("\(score.comparisons)", 10))"
                  + "\(pad("\(score.proposed)", 10))\(pad("\(score.decided)", 8))"
                  + "\(String(format: "%.1f", score.rate))")
        }
        print("  \(pad("all", 12))\(pad("", 8))\(pad("\(overall.comparisons)", 10))"
              + "\(pad("\(overall.proposed)", 10))\(pad("\(overall.decided)", 8))"
              + "\(String(format: "%.1f", overall.rate))")

        for (system, score) in worst.sorted(by: { $0.1.rate > $1.1.rate }).prefix(3)
        where !score.examples.isEmpty {
            print("\n  \(system) — wrongly merged:")
            for example in score.examples { print("    \(example)") }
        }
    }

    // MARK: - The same person's other names should be reached

    static func recall(at path: String) throws {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var pairs: [(String, String)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 3 else { continue }
            pairs.append((String(parts[1]), String(parts[2])))
        }
        guard !pairs.isEmpty else { return }

        var reached = 0, reachable = 0, reachableHit = 0
        var missed: [String] = []
        for (name, alias) in pairs {
            let hit = Entity.normalize(name) == Entity.normalize(alias)
                || Resolver.matchKind(name, alias) != nil
            if hit { reached += 1 }
            if sharesAToken(name, alias) {
                reachable += 1
                if hit { reachableHit += 1 } else if missed.count < 6 {
                    missed.append("\(name)  ↛  \(alias)")
                }
            }
        }

        print("\n── names · the same person's other spellings " + String(repeating: "─", count: 17))
        print("  \(pad("all aliases", 22))\(percent(reached, pairs.count))   \(reached)/\(pairs.count)")
        print("  \(pad("sharing a name token", 22))\(percent(reachableHit, reachable))   \(reachableHit)/\(reachable)")
        print("  the gap is epithets and stage names — no string algorithm reaches those;")
        print("  they are what the shared-context rungs are for.")
        if !missed.isEmpty {
            print("\n  reachable but missed:")
            for example in missed { print("    \(example)") }
        }
    }

    /// Whether any string comparison could plausibly connect the two at all.
    private static func sharesAToken(_ a: String, _ b: String) -> Bool {
        let left = Set(Entity.normalize(a).split(separator: " ").map(String.init))
        let right = Set(Entity.normalize(b).split(separator: " ").map(String.init))
        // A bare initial shared by two names says nothing — half the alphabet shares one.
        return !left.intersection(right).filter { $0.count > 1 }.isEmpty
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "  n/a" : String(format: "%4.0f%%", Double(part) / Double(whole) * 100)
    }
}
