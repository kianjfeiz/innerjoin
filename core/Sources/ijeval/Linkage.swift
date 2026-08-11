import Foundation
import InnerjoinCore

/// Scores name matching against a published benchmark, beside the standard algorithm.
///
/// FEBRL is the long-standing public test set for person record linkage: synthetic people
/// with ground-truth duplicates carrying the errors real data carries — dropped letters,
/// transpositions, substituted given names, missing fields.
///
/// The comparison is deliberately fair on information. FEBRL's own labels are derived from
/// every field, including address and date of birth, so *no* name-only matcher can reach
/// full recall — several "duplicates" differ in both given name and surname and are only
/// identifiable by where they live. So the baseline sees exactly what the ladder sees, the
/// full name and nothing else, and the question is which does more with it.
///
/// The baseline is Jaro-Winkler at a fixed threshold, which is what Splink, dedupe and
/// fastLink all reduce to for a name field.
enum Linkage {
    struct Outcome {
        var truePositives = 0, falsePositives = 0, falseNegatives = 0, trueNegatives = 0
        /// Negatives that share a surname — the ones that separate a matcher from a
        /// string comparison.
        var hardFalsePositives = 0

        var precision: Double { truePositives + falsePositives == 0 ? 1
            : Double(truePositives) / Double(truePositives + falsePositives) }
        var recall: Double { truePositives + falseNegatives == 0 ? 1
            : Double(truePositives) / Double(truePositives + falseNegatives) }
        var f1: Double { precision + recall == 0 ? 0
            : 2 * precision * recall / (precision + recall) }
    }

    static func run(pairsAt path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var pairs: [(String, String, Bool)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            pairs.append((String(parts[0]), String(parts[1]), parts[2] == "1"))
        }
        guard !pairs.isEmpty else { print("No pairs at \(path)."); return }

        print("FEBRL person-name linkage · \(pairs.count) labelled pairs")
        print("  \(pairs.filter(\.2).count) duplicates · \(pairs.filter { !$0.2 }.count) distinct\n")

        var results: [(String, Outcome)] = []

        // The ladder, in the two ways the resolver actually uses it.
        results.append(("innerjoin — any match kind", score(pairs) {
            Resolver.matchKind($0, $1) != nil
        }))
        results.append(("innerjoin — decides alone (rung 4)", score(pairs) {
            switch Resolver.matchKind($0, $1) {
            case .subsequence, .initials: return true
            default: return false
            }
        }))

        // The ladder with graded similarity, swept, so the threshold is chosen on
        // evidence instead of taste.
        for threshold in [0.88, 0.90, 0.92, 0.94] {
            results.append(("innerjoin + similarity ≥ \(threshold)", score(pairs) {
                if Resolver.matchKind($0, $1) != nil, Resolver.matchKind($0, $1) != .similar {
                    return true
                }
                return Resolver.similarity($0, $1) >= threshold
            }))
        }

        // Rarity weighting — the Fellegi-Sunter idea the ladder was missing.
        //
        // A shared surname is not one quantity of evidence. "Ramirez" appearing once in a
        // library nearly identifies a person on its own; "Smith" appearing twelve times
        // barely narrows anything. The ladder demanded the same corroboration for both,
        // which is why recall stalled: the safe cases were being refused alongside the
        // dangerous ones.
        //
        // Surname frequency is taken from the population itself, exactly as those tools
        // estimate u-probabilities from the data rather than from a table.
        var surnameCount: [String: Int] = [:]
        var seenNames = Set<String>()
        for (left, right, _) in pairs {
            for name in [left, right] where seenNames.insert(name).inserted {
                if let surname = name.split(separator: " ").last {
                    surnameCount[String(surname), default: 0] += 1
                }
            }
        }
        func rarity(_ name: String) -> Int {
            guard let surname = name.split(separator: " ").last else { return 99 }
            return surnameCount[String(surname)] ?? 1
        }

        for ceiling in [1, 2, 3] {
            results.append(("innerjoin + rarity (surname ≤ \(ceiling))", score(pairs) { left, right in
                switch Resolver.matchKind(left, right) {
                case .subsequence, .initials:
                    return true
                case .similar, .typo, .nickname:
                    // A weak resemblance decides alone only when the surname is rare
                    // enough that few other people could be behind it.
                    return max(rarity(left), rarity(right)) <= ceiling
                case .none:
                    return false
                }
            }))
        }

        // The published baseline, at the thresholds those tools ship with.
        for threshold in [0.85, 0.90, 0.95] {
            results.append(("Jaro-Winkler ≥ \(threshold)", score(pairs) {
                jaroWinkler($0, $1) >= threshold
            }))
        }

        let width = results.map(\.0.count).max() ?? 20
        print("  \("method".padding(toLength: width, withPad: " ", startingAt: 0))   prec  recall  F1     wrong merges of same-surname people")
        for (name, outcome) in results {
            print(String(format: "  %@   %4.0f%%  %4.0f%%  %4.0f%%   %d",
                         name.padding(toLength: width, withPad: " ", startingAt: 0),
                         outcome.precision * 100, outcome.recall * 100, outcome.f1 * 100,
                         outcome.hardFalsePositives))
        }
    }

    static func score(_ pairs: [(String, String, Bool)],
                      _ matches: (String, String) -> Bool) -> Outcome {
        var outcome = Outcome()
        for (left, right, isDuplicate) in pairs {
            let predicted = matches(left, right)
            switch (isDuplicate, predicted) {
            case (true, true):   outcome.truePositives += 1
            case (true, false):  outcome.falseNegatives += 1
            case (false, true):
                outcome.falsePositives += 1
                if left.split(separator: " ").last == right.split(separator: " ").last {
                    outcome.hardFalsePositives += 1
                }
            case (false, false): outcome.trueNegatives += 1
            }
        }
        return outcome
    }

    /// Jaro-Winkler, as the record-linkage literature defines it.
    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let first = Array(a), second = Array(b)
        if first.isEmpty || second.isEmpty { return first == second ? 1 : 0 }
        if first == second { return 1 }

        let window = max(first.count, second.count) / 2 - 1
        var firstMatched = [Bool](repeating: false, count: first.count)
        var secondMatched = [Bool](repeating: false, count: second.count)
        var matches = 0

        for i in first.indices {
            let low = max(0, i - max(0, window))
            let high = min(second.count - 1, i + max(0, window))
            guard low <= high else { continue }
            for j in low...high where !secondMatched[j] && first[i] == second[j] {
                firstMatched[i] = true; secondMatched[j] = true; matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0, k = 0
        for i in first.indices where firstMatched[i] {
            while !secondMatched[k] { k += 1 }
            if first[i] != second[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(first.count) + m / Double(second.count)
                    + (m - Double(transpositions) / 2) / m) / 3

        // Winkler's boost for a shared prefix, capped at four characters.
        var prefix = 0
        for (x, y) in zip(first, second) {
            if x != y { break }
            prefix += 1
            if prefix == 4 { break }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}
