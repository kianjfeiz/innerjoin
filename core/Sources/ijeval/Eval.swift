import Foundation
import InnerjoinCore

/// Scores the whole pipeline against a corpus whose truth is known.
///
/// Run at several noise levels: a flawless model, a realistic one, and a bad one. What
/// matters isn't the score at zero noise — it's how gently the numbers fall as the
/// model gets worse, because that decay is the part of the system we control.
@main
struct Eval {
    static func main() async throws {
        let levels = ProcessInfo.processInfo.arguments.contains("--quick")
            ? [0.4] : [0.0, 0.4, 0.9]

        var allPassed = true
        for noise in levels {
            let report = try await run(noise: noise)
            report.print()
            allPassed = allPassed && report.passed
        }
        print(allPassed ? "\nAll thresholds met." : "\nSome thresholds missed.")
        if !allPassed { exit(1) }
    }

    static func run(noise: Double) async throws -> Report {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ijeval-\(UUID().uuidString)")
        let corpusFolder = root.appendingPathComponent("corpus")
        defer { try? FileManager.default.removeItem(at: root) }

        let truth = try Corpus.build(in: corpusFolder)
        let failures = try Corpus.buildFailures(in: corpusFolder.appendingPathComponent("broken"))
        let byFile = Dictionary(uniqueKeysWithValues: truth.map { ($0.file, $0) })
        let store = try Store(root: root.appendingPathComponent("workspace"))

        let librarian = Librarian(
            store: store,
            provider: Simulator(expected: byFile, noise: noise),
            understandingLanes: 4
        )
        _ = try await librarian.absorb([corpusFolder])

        var report = try score(store: store, truth: truth, noise: noise)
        report.brokenFilesExpected = failures.count
        let all = try store.recentDocuments(limit: 500)
        report.brokenFilesHandled = failures.filter { name in
            // Either refused outright, or kept with a readable reason. Both are fine;
            // a broken file silently succeeding is not.
            guard let doc = all.first(where: { $0.name == name }) else { return true }
            return doc.status == .failed && (doc.problem?.isEmpty == false)
        }.count
        return report
    }

    // MARK: - Scoring

    static func score(store: Store, truth: [Corpus.Expected], noise: Double) throws -> Report {
        var report = Report(noise: noise)
        let documents = try store.recentDocuments(limit: 500)
        report.filesExpected = truth.count
        report.filesRead = documents.filter { $0.status != .failed }.count

        // --- reading: did the words survive? ---
        var factsExpected = 0, factsFound = 0
        for expectation in truth {
            guard let document = documents.first(where: { $0.name == expectation.file }) else { continue }
            let markdown = document.markdown ?? ""
            for fact in expectation.facts {
                factsExpected += 1
                if markdown.contains(fact) { factsFound += 1 }
                else { report.missedFacts.append("\(expectation.file): \(fact)") }
            }
        }
        report.factsExpected = factsExpected
        report.factsFound = factsFound

        // --- entities: right ones kept, scenery kept out ---
        let entities = try store.entities(limit: 500)
        let names = Set(entities.map { Entity.normalize($0.name) })
        let aliases = Set(entities.flatMap { $0.aliases.map(Entity.normalize) })
        let known = names.union(aliases)

        var wanted = Set<String>(), unwanted = Set<String>()
        for expectation in truth {
            for name in expectation.entities { wanted.insert(Entity.normalize(name)) }
            for name in expectation.scenery { unwanted.insert(Entity.normalize(name)) }
        }
        report.entitiesExpected = wanted.count
        report.entitiesFound = wanted.filter { want in
            known.contains { $0 == want || $0.contains(want) || want.contains($0) }
        }.count
        report.sceneryAdmitted = unwanted.filter { names.contains($0) }.count
        report.entityTotal = entities.count
        report.missedEntities = wanted.filter { want in
            !known.contains { $0 == want || $0.contains(want) || want.contains($0) }
        }.sorted()
        report.admittedScenery = unwanted.filter { names.contains($0) }.sorted()

        // --- categories: does each cluster hold one real area? ---
        var byCategory: [String: [String]] = [:]
        for document in documents {
            guard let id = document.id, let record = try store.record(ofDocument: id) else { continue }
            byCategory[record.category ?? "—", default: []].append(document.name)
        }
        report.categories = byCategory.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }

        var placed = 0, pure = 0
        for (name, files) in byCategory where name != Organize.holdingCategory && name != "—" {
            let areas = files.compactMap { file in truth.first { $0.file == file }?.area }
            guard !areas.isEmpty else { continue }
            placed += files.count
            // A cluster is pure when everything in it belongs to the same real area.
            let dominant = Dictionary(grouping: areas, by: { $0 }).values.map(\.count).max() ?? 0
            pure += dominant
            if dominant < areas.count {
                let mixture = Dictionary(grouping: areas, by: { $0 }).mapValues(\.count)
                report.impureCategories.append("\(name): \(mixture)")
            }
        }
        report.documentsCategorized = placed
        report.documentsInPureCategory = pure

        // --- citations: does every stored source resolve? ---
        var cited = 0, resolvable = 0
        for document in documents {
            guard let id = document.id, let record = try store.record(ofDocument: id) else { continue }
            let tags = Set(try store.elements(of: id).map(\.tag))
            for field in record.fields.values {
                guard let source = field.source else { continue }
                cited += 1
                if tags.contains(source) { resolvable += 1 }
            }
        }
        report.citationsStored = cited
        report.citationsValid = resolvable

        report.entityNames = entities.map { entity in
            let count = (try? store.records(linkedTo: entity.id ?? 0).count) ?? 0
            let alias = entity.aliases.isEmpty ? "" : " (+\(entity.aliases.joined(separator: ",")))"
            return "\(entity.name)\(alias) ×\(count)"
        }.sorted()

        let health = try store.graphHealth()
        report.singletonShare = health.singletonShare
        report.entitiesPerRecord = health.entitiesPerRecord
        return report
    }
}

struct Report {
    let noise: Double
    var filesExpected = 0, filesRead = 0
    var factsExpected = 0, factsFound = 0
    var entitiesExpected = 0, entitiesFound = 0, entityTotal = 0, sceneryAdmitted = 0
    var documentsCategorized = 0, documentsInPureCategory = 0
    var citationsStored = 0, citationsValid = 0
    var singletonShare = 0.0, entitiesPerRecord = 0.0
    var categories: [(String, Int)] = []
    var missedFacts: [String] = []
    var missedEntities: [String] = []
    var admittedScenery: [String] = []
    var impureCategories: [String] = []
    var entityNames: [String] = []
    var brokenFilesExpected = 0, brokenFilesHandled = 0

    var readRate: Double { ratio(filesRead, filesExpected) }
    var factRate: Double { ratio(factsFound, factsExpected) }
    var entityRecall: Double { ratio(entitiesFound, entitiesExpected) }
    var categoryPurity: Double { ratio(documentsInPureCategory, documentsCategorized) }
    var citationValidity: Double { citationsStored == 0 ? 1 : ratio(citationsValid, citationsStored) }

    private func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 1 : Double(a) / Double(b) }

    /// Thresholds are the contract. Reading is deterministic so it must be near-perfect;
    /// the rest is allowed to degrade with noise, but never to collapse — and citations
    /// must *always* be valid, because a citation that opens nothing destroys trust.
    var passed: Bool {
        readRate >= 0.95 && factRate >= 0.90 && citationValidity >= 0.999
            && entityRecall >= 0.85 && categoryPurity >= 0.80 && sceneryAdmitted == 0
            && brokenFilesHandled == brokenFilesExpected
    }

    func print() {
        let percent = { (value: Double) in String(format: "%3.0f%%", value * 100) }
        Swift.print("\n── model noise \(Int(noise * 100))% " + String(repeating: "─", count: 44))
        Swift.print("  files read          \(percent(readRate))   \(filesRead)/\(filesExpected)")
        Swift.print("  facts preserved     \(percent(factRate))   \(factsFound)/\(factsExpected)")
        Swift.print("  entities found      \(percent(entityRecall))   \(entitiesFound)/\(entitiesExpected)  (\(entityTotal) total, \(String(format: "%.1f", entitiesPerRecord))/record)")
        Swift.print("  scenery kept out    \(sceneryAdmitted == 0 ? " yes" : "  NO")   \(admittedScenery.joined(separator: ", "))")
        Swift.print("  category purity     \(percent(categoryPurity))   \(documentsInPureCategory)/\(documentsCategorized) placed")
        Swift.print("  citations valid     \(percent(citationValidity))   \(citationsValid)/\(citationsStored)")
        Swift.print("  singleton entities  \(percent(singletonShare))")
        Swift.print("  broken files        \(brokenFilesHandled == brokenFilesExpected ? " ok" : " NO")   \(brokenFilesHandled)/\(brokenFilesExpected) failed visibly")
        Swift.print("  categories: " + (categories.isEmpty ? "none"
            : categories.map { "\($0.0) \($0.1)" }.joined(separator: " · ")))
        for line in missedFacts.prefix(6)      { Swift.print("    missed fact:    \(line)") }
        for line in missedEntities.prefix(6)   { Swift.print("    missed entity:  \(line)") }
        for line in impureCategories.prefix(6) { Swift.print("    mixed category: \(line)") }
        Swift.print("  entities: " + entityNames.joined(separator: " | "))
        Swift.print("  → \(passed ? "meets thresholds" : "BELOW THRESHOLD")")
    }
}
