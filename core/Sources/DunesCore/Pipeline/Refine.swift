import Foundation
import GRDB

/// Reads documents again once the library knows more than it did the first time.
///
/// The first document of a kind is read with nothing to go on, so whatever it calls
/// the rent is what it calls the rent. By the tenth, a category has settled on a
/// vocabulary — and the early documents are now the odd ones out, describing the same
/// facts in words nobody else uses.
///
/// This is what "learning" means here. No weights change; the library's own accumulated
/// vocabulary is handed back to the model, and the documents that disagree with their
/// peers are read a second time in that light. It converges because each pass makes the
/// dominant vocabulary stronger, and stops when nothing is left that diverges.
public struct Refine: Sendable {
    let store: Store
    let provider: any ModelProvider

    /// A record is worth re-reading when this much of its vocabulary is unlike its
    /// category's. Low enough to catch genuine drift, high enough that a document with
    /// one legitimately unusual field isn't re-read forever.
    static let divergenceThreshold = 0.34

    /// Categories smaller than this have no settled vocabulary to conform to, and
    /// forcing agreement between two documents would just be noise.
    static let minimumCategorySize = 3

    public init(store: Store, provider: any ModelProvider) {
        self.store = store
        self.provider = provider
    }

    public struct Pass: Sendable {
        public let reread: [String]
        public let coherenceBefore: Double
        public let coherenceAfter: Double
    }

    /// Runs passes until the library stops changing, or `limit` is reached.
    @discardableResult
    public func run(limit: Int = 3) async throws -> [Pass] {
        var passes: [Pass] = []
        let distill = Distill(store: store, provider: provider)

        for _ in 0..<limit {
            let before = try coherence()
            let divergent = try divergentRecords()
            guard !divergent.isEmpty else { break }

            var reread: [String] = []
            for (documentID, name) in divergent {
                // A failure here is not fatal: the record already exists and keeps
                // whatever it said the first time.
                if (try? await distill.understand(documentID: documentID)) != nil {
                    reread.append(name)
                }
            }
            let after = try coherence()
            passes.append(Pass(reread: reread, coherenceBefore: before, coherenceAfter: after))

            // Stop the moment a pass stops helping, rather than churning the library
            // and spending tokens for nothing.
            if after <= before { break }
        }
        return passes
    }

    /// Records whose field names are unlike the rest of their category's.
    public func divergentRecords() throws -> [(documentID: Int64, name: String)] {
        var out: [(Int64, String)] = []
        let records = try store.records(limit: 5_000)
        let byCategory = Dictionary(grouping: records) { $0.category ?? "" }

        for (category, group) in byCategory {
            guard !category.isEmpty, category != Organize.holdingCategory,
                  group.count >= Self.minimumCategorySize else { continue }

            // How many records in this category use each field name.
            var usage: [String: Int] = [:]
            for record in group {
                for name in record.fields.keys { usage[name, default: 0] += 1 }
            }
            // A name most of the category agrees on is the settled one.
            let settled = Set(usage.filter { Double($0.value) / Double(group.count) > 0.5 }.keys)
            guard !settled.isEmpty else { continue }

            for record in group {
                let names = Set(record.fields.keys)
                guard !names.isEmpty else { continue }
                // Only count names that are *contested* — used by this record but not
                // settled, while the category has settled on something else.
                let odd = names.subtracting(settled)
                let share = Double(odd.count) / Double(names.count)
                guard share >= Self.divergenceThreshold,
                      let document = try store.document(id: record.documentID) else { continue }
                out.append((record.documentID, document.name))
            }
        }
        return out
    }

    /// Fraction of field uses that sit on their category's most common name for that
    /// field. Rises as the library agrees with itself.
    public func coherence() throws -> Double {
        let records = try store.records(limit: 5_000)
        let byCategory = Dictionary(grouping: records) { $0.category ?? "" }
        var uses = 0, onDominant = 0

        for (category, group) in byCategory where !category.isEmpty {
            var usage: [String: Int] = [:]
            for record in group {
                for name in record.fields.keys { usage[name, default: 0] += 1 }
            }
            uses += usage.values.reduce(0, +)
            onDominant += usage.values.max() ?? 0
        }
        return uses == 0 ? 1 : Double(onDominant) / Double(uses)
    }
}
