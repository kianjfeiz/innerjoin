import Foundation
import GRDB

/// How alike two documents read, independent of who they name.
///
/// Clustering by shared entities alone turned out to be unstable against a real model,
/// and the reason is structural rather than a bad threshold. A document's cluster can
/// hinge on a single entity, and a model reading the same page twice names a slightly
/// different set — so on one run the utility bill shares the landlord with the lease and
/// joins it, and on the next it doesn't and sits alone. Measured over twenty-two runs,
/// category purity swung between 44% and 100% with nothing changed in between.
///
/// No threshold fixes that, because the input itself moves. What fixes it is a second
/// signal that doesn't depend on the model's choices at all: two rent invoices from the
/// same landlord read alike whether or not extraction happened to name him. Words are
/// what the document actually contains, so they're stable across readings.
///
/// Plain TF-IDF over the words, cosine similarity between documents. Deterministic, no
/// model call, no embedding table — and inspectable, which matters when a category comes
/// out wrong and someone has to say why.
public struct Similarity: Sendable {

    /// Below this, two documents are merely written in the same language.
    public static let relatedThreshold = 0.14
    /// A pair this alike is evidence of a relationship on its own, without a shared name.
    public static let strongThreshold = 0.30
    /// Terms in more than this share of the library carry no information — the textual
    /// equivalent of a hub entity.
    static let ubiquitousTerm = 0.5
    /// Only the beginning of a long document. A lease's first page says what it is; page
    /// nine is boilerplate that every lease shares, which would make all of them alike.
    static let charactersConsidered = 4_000

    public struct Pair: Sendable {
        public let a: Int64
        public let b: Int64
        public let score: Double
    }

    /// Every pair of records that reads alike, and how much.
    ///
    /// Built through an inverted index rather than comparing all pairs, so a library of
    /// thousands doesn't become a million comparisons: only documents that share a term
    /// are ever scored against each other.
    public static func pairs(among documents: [(id: Int64, text: String)]) -> [Pair] {
        guard documents.count > 1 else { return [] }

        let termsOf = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, terms(in: $0.text)) })
        var documentsWith: [String: [Int64]] = [:]
        for (id, terms) in termsOf {
            for term in terms.keys { documentsWith[term, default: []].append(id) }
        }

        let total = Double(documents.count)
        var idf: [String: Double] = [:]
        for (term, holders) in documentsWith {
            let share = Double(holders.count) / total
            // A term in half the library says as little as an entity attached to half of
            // it, and both wreck clustering the same way.
            guard share <= ubiquitousTerm, holders.count > 1 else { continue }
            idf[term] = log(total / Double(holders.count))
        }

        // Vector lengths, so the scores below are cosines rather than raw overlaps —
        // otherwise a long document looks related to everything.
        var norm: [Int64: Double] = [:]
        for (id, terms) in termsOf {
            var sum = 0.0
            for (term, count) in terms {
                guard let weight = idf[term] else { continue }
                sum += pow(Double(count) * weight, 2)
            }
            norm[id] = sum > 0 ? sqrt(sum) : 0
        }

        var dot: [Int64: [Int64: Double]] = [:]
        for (term, holders) in documentsWith {
            guard let weight = idf[term], holders.count > 1 else { continue }
            // A term in very many documents would generate a pair for every combination
            // of them; it has been established above that such a term says nothing.
            guard Double(holders.count) / total <= ubiquitousTerm else { continue }
            for a in holders {
                let left = Double(termsOf[a]?[term] ?? 0) * weight
                for b in holders where b > a {
                    let right = Double(termsOf[b]?[term] ?? 0) * weight
                    dot[a, default: [:]][b, default: 0] += left * right
                }
            }
        }

        var out: [Pair] = []
        for (a, others) in dot {
            guard let leftNorm = norm[a], leftNorm > 0 else { continue }
            for (b, product) in others {
                guard let rightNorm = norm[b], rightNorm > 0 else { continue }
                let score = product / (leftNorm * rightNorm)
                if score >= relatedThreshold { out.append(Pair(a: a, b: b, score: score)) }
            }
        }
        return out
    }

    /// Words worth counting, with how often each appears.
    static func terms(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for raw in String(text.prefix(charactersConsidered))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        {
            let word = raw.lowercased()
            // Numbers are dropped on purpose. Two invoices from the same vendor share
            // their vocabulary; the amounts are exactly what differs between them, and
            // counting those makes two unrelated documents that happen to cost the same
            // look related.
            guard word.count > 3, word.count < 24,
                  word.rangeOfCharacter(from: .decimalDigits) == nil,
                  !stopWords.contains(word)
            else { continue }
            counts[word, default: 0] += 1
        }
        return counts
    }

    /// Words that appear in every kind of document, so they'd relate all of them.
    /// Short on purpose — IDF already handles anything common in *this* library, and this
    /// only has to cover the general-English case where the library is too small for the
    /// statistics to have settled.
    static let stopWords: Set<String> = [
        "this", "that", "these", "those", "with", "from", "have", "has", "had", "been",
        "will", "shall", "would", "should", "must", "may", "any", "all", "such", "each",
        "which", "there", "their", "them", "then", "than", "when", "what", "were", "was",
        "your", "yours", "you", "our", "ours", "into", "upon", "under", "over", "also",
        "other", "more", "most", "some", "only", "same", "both", "here", "does", "made",
        "make", "made", "page", "date", "dated", "please", "thank", "regards", "sincerely",
        "email", "phone", "address", "name", "number", "total", "amount", "document",
    ]
}

public extension Store {
    /// The text clustering compares: what the document is *about*, not every word in it.
    ///
    /// The record's own words come first and are repeated, because a title and a summary
    /// are a distilled statement of the subject while the body is full of boilerplate
    /// every document of that kind shares.
    func comparableText(of record: Record, markdown: String?) -> String {
        var parts: [String] = []
        for _ in 0..<3 {
            parts.append(record.title)
            if let kind = record.kind { parts.append(kind) }
        }
        if let summary = record.summary { parts.append(summary) }
        parts.append(record.fields.keys.joined(separator: " "))
        parts.append(record.fields.values.map(\.value).joined(separator: " "))
        if let markdown { parts.append(markdown) }
        return parts.joined(separator: " ")
    }
}
