import Foundation
import DunesCore

/// Scores the whole pipeline against a corpus whose truth is known.
///
/// Run at several noise levels: a flawless model, a realistic one, and a bad one. What
/// matters isn't the score at zero noise — it's how gently the numbers fall as the
/// model gets worse, because that decay is the part of the system we control.
@main
struct Eval {
    static func main() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let quick = arguments.contains("--quick")

        // The same corpus, the same known truth, a real model instead of the simulator.
        // Every number the simulator produces is a claim about a program I wrote to
        // imitate a model; this is the only way to find out which of those claims hold.
        // Identity is scored on its own corpus and its own run: the documents exist to
        // break resolution, not to be read, and mixing them into the main numbers would
        // hide both.
        // Against a published benchmark, beside the published algorithm.
        if let index = arguments.firstIndex(of: "--linkage") {
            let path = arguments.count > index + 1 ? arguments[index + 1] : "febrl_pairs.tsv"
            try Linkage.run(pairsAt: path)
            return
        }

        // Against a corpus whose faults are written down.
        if let index = arguments.firstIndex(of: "--errors") {
            let directory = arguments.count > index + 1 ? arguments[index + 1] : "."
            try await Errors.run(corpus: directory,
                                 manifest: directory + "/ERRORS_MANIFEST.md")
            return
        }

        // Real names from every naming system, against the matcher alone.
        if let index = arguments.firstIndex(of: "--names") {
            let directory = arguments.count > index + 1 ? arguments[index + 1] : "."
            try Names.run(distinctAt: directory + "/names_distinct.tsv",
                          variantsAt: directory + "/names_variants.tsv")
            return
        }

        if arguments.contains("--people") {
            try await runPeople()
            return
        }

        if arguments.contains("--real") {
            // A single run of this corpus is one sample, not a measurement: the model
            // returns different output for byte-identical requests, seed and all.
            if let index = arguments.firstIndex(of: "--repeat"),
               let count = arguments.count > index + 1 ? Int(arguments[index + 1]) : nil,
               count > 1 {
                try await runTrials(count: count, settle: !arguments.contains("--no-settle"))
                return
            }
            try await runAgainstRealModel(settle: !arguments.contains("--no-settle"))
            return
        }

        let levels = quick ? [0.4] : [0.0, 0.4, 0.9]

        var allPassed = true
        for noise in levels {
            var report = try await run(noise: noise, mode: .learning, keepWorkspace: true)
            if let store = report.store {
                let byFile = Dictionary(uniqueKeysWithValues:
                    try Corpus.build(in: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("duneseval-questions-\(Int(noise * 100))"))
                        .map { ($0.file, $0) })
                report.reasoning = try await scoreReasoning(
                    store: store, provider: Simulator(expected: byFile, noise: noise))
            }
            report.print()
            allPassed = allPassed && report.passed
        }

        // What the learning loop is actually worth, measured rather than asserted.
        print("\n══ what the library learns from itself " + String(repeating: "═", count: 25))
        for noise in (quick ? [0.4] : [0.0, 0.4, 0.9]) {
            let cold = try await run(noise: noise, mode: .noLearning)
            let warm = try await run(noise: noise, mode: .learning)
            let converged = try await run(noise: noise, mode: .refined)
            print(String(format: "  noise %2.0f%%   nothing fed back %3.0f%%  →  vocabulary fed back %3.0f%%  →  after re-reading %3.0f%%",
                         noise * 100,
                         cold.schemaCoherence * 100,
                         warm.schemaCoherence * 100,
                         converged.schemaCoherence * 100))
            // Feeding the library's own vocabulary back must measurably help, and
            // re-reading must not undo it. Both are the point of the loop.
            if warm.schemaCoherence <= cold.schemaCoherence + 0.05 { allPassed = false }
            if converged.schemaCoherence + 0.001 < warm.schemaCoherence { allPassed = false }
            if converged.schemaCoherence < 0.92 { allPassed = false }
        }

        print(allPassed ? "\nAll thresholds met." : "\nSome thresholds missed.")
        if !allPassed { exit(1) }
    }

    static func runPeople() async throws {
        let settings = ProviderSettings.fromEnvironment()
        guard settings.kind != .mock else { print("--people needs a provider."); exit(1) }
        print("Identity corpus · \(settings.makeProvider().label)")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ijpeople-\(UUID().uuidString)")
        let corpus = root.appendingPathComponent("corpus")
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try PeopleCorpus.build(in: corpus)
        let store = try Store(root: root.appendingPathComponent("workspace"))
        await Meter.shared.reset()

        // Ingested one at a time, in written order, because order is part of what's being
        // tested: Joanna is established before Jose arrives and makes her initial
        // ambiguous. A batch would hide an order-dependent bug.
        let librarian = Librarian(store: store, provider: settings.makeProvider(),
                                  understandingLanes: 1)
        // A document that fails to read changes the order everything after it resolves
        // in, so a silent failure here shows up as an identity bug three documents later.
        // It gets reported as itself.
        for file in files {
            let summary = try await librarian.absorb([corpus.appendingPathComponent(file)],
                                                     settle: false)
            for problem in summary.problems {
                print("  ! \(problem.file): \(problem.reason)")
            }
        }

        let score = try PeopleCorpus.score(store: store)
        score.print()
        let spend = await Meter.shared.snapshot()
        print("\n  cost: \(spend.description)")
        if !score.passed { exit(1) }
    }

    /// The same corpus, several times, reported with its spread.
    ///
    /// Necessary rather than thorough. Two consecutive runs of this corpus — same binary,
    /// same seed, same temperature, nothing changed between them — scored 67% and 83% on
    /// category purity and 84% and 92% on coverage. Neither number was wrong; a single
    /// run simply isn't a measurement of anything, and a change judged by one is judged
    /// by noise. Reporting the spread beside the mean is what makes "this helped"
    /// something you can check: if the bands overlap, it didn't, or not measurably.
    ///
    /// The deterministic benchmarks — `--names`, `--linkage`, `dunescheck` — need none of
    /// this, which is exactly why the resolver work is measured there.
    static func runTrials(count: Int, settle: Bool) async throws {
        let settings = ProviderSettings.fromEnvironment()
        guard settings.kind != .mock else { print("--real needs a provider."); exit(1) }
        print("Real model: \(settings.makeProvider().label) · \(count) runs of the same corpus\n")

        var samples: [String: [Double]] = [:]
        var order: [String] = []
        func note(_ name: String, _ value: Double) {
            if samples[name] == nil { order.append(name) }
            samples[name, default: []].append(value)
        }

        await Meter.shared.reset()
        for trial in 1...count {
            let provider = settings.makeProvider()
            var report = try await run(noise: 0, mode: settle ? .refined : .learning,
                                       provider: provider, keepWorkspace: true)
            if let store = report.store {
                report.reasoning = try await scoreReasoning(store: store, provider: provider)
            }
            note("files read", report.readRate)
            note("facts preserved", report.factRate)
            note("entities found", report.entityRecall)
            note("citations valid", report.citationValidity)
            note("schema coherence", report.schemaCoherence)
            note("named from contents", report.namedShare)
            note("category purity", report.categoryPurity)
            note("category coverage", report.categoryCoverage)
            if let reasoning = report.reasoning {
                note("answers correct", reasoning.accuracy)
                note("refused correctly", reasoning.refusalRate)
                note("citations resolve", reasoning.citationValidity)
            }
            print("  run \(trial) of \(count) done")
        }

        print("\n── \(count) runs · mean and spread " + String(repeating: "─", count: 28))
        print("  \(padded("metric", 22))\(padded("mean", 8))\(padded("worst", 8))\(padded("best", 8))spread")
        for name in order {
            let values = samples[name]!
            let mean = values.reduce(0, +) / Double(values.count)
            let low = values.min()!, high = values.max()!
            let flag = high - low >= 0.10 ? "  ← unstable" : ""
            print("  \(padded(name, 22))\(percent(mean))    \(percent(low))    \(percent(high))"
                  + "   \(percent(high - low))\(flag)")
        }
        let spend = await Meter.shared.snapshot()
        print("\n  cost: \(spend.description)")
    }

    private static func percent(_ value: Double) -> String { String(format: "%3.0f%%", value * 100) }

    private static func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// One pass of the corpus through whatever model the environment points at, in the
    /// configuration the app actually uses.
    static func runAgainstRealModel(settle: Bool) async throws {
        let settings = ProviderSettings.fromEnvironment()
        guard settings.kind != .mock else {
            print("--real needs a provider. Set DUNES_PROVIDER, and a key.")
            exit(1)
        }
        print("Real model: \(settings.makeProvider().label)")
        print("Corpus: 22 documents with known truth, plus 3 broken files.\n")

        await Meter.shared.reset()
        let provider = settings.makeProvider()
        var report = try await run(noise: 0, mode: settle ? .refined : .learning,
                                  provider: provider, keepWorkspace: true)
        let ingestionSpend = await Meter.shared.snapshot()

        // Reading the documents right is half the job. This is the other half.
        if let store = report.store {
            report.reasoning = try await scoreReasoning(store: store, provider: provider)
        }
        report.print()

        let spend = await Meter.shared.snapshot()
        print(String(format: "  of which ingestion: %d calls, %d tokens",
                     ingestionSpend.calls, ingestionSpend.inputTokens + ingestionSpend.outputTokens))
        print("\n  cost: \(spend.description)")
        if report.documentsUnderstood > 0 {
            let perDocument = Double(spend.inputTokens + spend.outputTokens)
                / Double(report.documentsUnderstood)
            print(String(format: "        %.0f tokens per document", perDocument))
        }
        print(report.passed ? "\nMeets thresholds." : "\nBELOW THRESHOLD.")
        if !report.passed { exit(1) }
    }

    /// Asks the corpus's known questions and scores the answers.
    ///
    /// Three things are measured, and the third matters most. Whether the right value
    /// appears; whether every citation resolves to a real element of a real document;
    /// and whether the questions the library cannot answer are refused. A system that
    /// scores well on the first two and invents answers to the third is not usable, so
    /// refusal is scored as strictly as accuracy.
    static func scoreReasoning(store: Store, provider: any ModelProvider) async throws -> Reasoning {
        var score = Reasoning()
        let asker = Ask(store: store, provider: provider)

        for question in Corpus.questions {
            let answer: Ask.Answer
            do {
                answer = try await asker.answer(question.text)
            } catch {
                score.errors.append("\(question.text) — \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                continue
            }
            score.citationsOffered += answer.citations.count + answer.invented
            score.citationsValid += answer.citations.count

            if question.unanswerable {
                score.refusalsExpected += 1
                if answer.answered {
                    score.wrong.append("INVENTED: \"\(question.text)\" → \(answer.text.prefix(110))")
                } else {
                    score.refusalsCorrect += 1
                }
                continue
            }

            score.asked += 1
            let found = Self.states(question.expected, in: answer.text)
            if found, answer.answered {
                score.correct += 1
                // An answer with no citation is a claim, not a finding — even when the
                // value happens to be right.
                if answer.citations.isEmpty { score.uncited += 1 }
            } else if !answer.answered {
                score.wrong.append("GAVE UP: \"\(question.text)\" (wanted \(question.expected))")
            } else {
                score.wrong.append("WRONG: \"\(question.text)\" wanted \(question.expected) — got \(answer.text.prefix(110))")
            }
        }
        return score
    }

    /// Whether an answer actually states the expected value.
    ///
    /// Literal containment, plus the date the same day can be written as. Scoring
    /// "You must respond by June 1, 2026" as wrong when the truth is 2026-06-01 measures
    /// my formatter, not the model. (The prompt separately asks for dates copied
    /// verbatim; that's a style rule, not a correctness one.)
    static func states(_ expected: String, in answer: String) -> Bool {
        if answer.localizedCaseInsensitiveContains(expected) { return true }
        guard let date = Dates.parseISO(expected) else { return false }
        return Self.dateSpellings(date).contains { answer.localizedCaseInsensitiveContains($0) }
    }

    static func dateSpellings(_ date: Date) -> [String] {
        ["MMMM d, yyyy", "MMM d, yyyy", "d MMMM yyyy", "M/d/yyyy", "d/M/yyyy", "MMMM d yyyy"]
            .map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                return formatter.string(from: date)
            }
    }

    struct Reasoning {
        var asked = 0, correct = 0, uncited = 0
        var refusalsExpected = 0, refusalsCorrect = 0
        var citationsOffered = 0, citationsValid = 0
        var wrong: [String] = []
        var errors: [String] = []

        var accuracy: Double { asked == 0 ? 0 : Double(correct) / Double(asked) }
        var refusalRate: Double {
            refusalsExpected == 0 ? 1 : Double(refusalsCorrect) / Double(refusalsExpected)
        }
        var citationValidity: Double {
            citationsOffered == 0 ? 1 : Double(citationsValid) / Double(citationsOffered)
        }
        /// Answering is only useful if it's also honest, so all three must hold.
        var passed: Bool {
            accuracy >= 0.80 && refusalRate >= 0.90 && citationValidity >= 0.95
                && errors.isEmpty
        }
    }

    enum Mode { case noLearning, learning, refined }

    static func run(noise: Double, mode: Mode,
                    provider explicit: (any ModelProvider)? = nil,
                    keepWorkspace: Bool = false) async throws -> Report {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("duneseval-\(UUID().uuidString)")
        let corpusFolder = root.appendingPathComponent("corpus")
        defer { if !keepWorkspace { try? FileManager.default.removeItem(at: root) } }

        let truth = try Corpus.build(in: corpusFolder)
        let failures = try Corpus.buildFailures(in: corpusFolder.appendingPathComponent("broken"))
        let byFile = Dictionary(uniqueKeysWithValues: truth.map { ($0.file, $0) })
        let store = try Store(root: root.appendingPathComponent("workspace"))

        let provider: any ModelProvider = explicit ?? Simulator(expected: byFile, noise: noise)
        let librarian = Librarian(
            store: store, provider: provider,
            understandingLanes: 4,
            learningEnabled: mode != .noLearning
        )
        _ = try await librarian.absorb([corpusFolder], settle: mode != .noLearning)
        if mode == .refined {
            _ = try await Refine(store: store, provider: provider).run()
            _ = try await Organize(store: store).run()
        }

        var report = try score(store: store, truth: truth, noise: noise)
        if keepWorkspace { report.store = store }
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
                if markdown.contains(fact.value) { factsFound += 1 }
                else { report.missedFacts.append("\(expectation.file): \(fact.value)") }
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

        // Which entities clustering threw away as uninformative — the single most
        // useful thing to see when categories come out wrong.
        report.ignoredHubs = (try? Organize(store: store).neighbours(of: try store.records(limit: 500)).hubs) ?? []

        // --- names: is each document called what it is, and only one thing? ---
        let understood = documents.filter { $0.stage == .understood }
        report.documentsUnderstood = understood.count
        report.documentsNamed = understood.filter(\.wasRenamed).count
        let derived = understood.compactMap(\.displayName)
        // Two documents showing the same name is the failure that matters: it makes the
        // library look like it has duplicates it doesn't have.
        report.namesUnique = Set(derived.map { $0.lowercased() }).count == derived.count
        report.nameExamples = understood.filter(\.wasRenamed).prefix(4)
            .map { "\($0.name)  →  \($0.label)" }

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

        // Schema coherence: within a category, does one fact concept have one name?
        // Three names for the same thing is three columns that can never be compared.
        var namesByConcept: [String: [String: Int]] = [:]
        for document in documents {
            guard let id = document.id, let record = try store.record(ofDocument: id),
                  let category = record.category else { continue }
            for name in record.fields.keys {
                guard let concept = Corpus.conceptOf[name] else { continue }
                namesByConcept["\(category)/\(concept)", default: [:]][name, default: 0] += 1
            }
        }
        var uses = 0, dominant = 0
        for (_, variants) in namesByConcept {
            let total = variants.values.reduce(0, +)
            uses += total
            dominant += variants.values.max() ?? 0
            if variants.count > 1 {
                report.splitConcepts.append(variants.keys.sorted().joined(separator: " / "))
            }
        }
        report.fieldUses = uses
        report.fieldUsesOnDominantName = dominant

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
    var fieldUses = 0, fieldUsesOnDominantName = 0
    var splitConcepts: [String] = []
    var documentsUnderstood = 0, documentsNamed = 0
    /// Kept only for a real-model run, where the questions are asked after scoring.
    var store: Store? = nil
    var reasoning: Eval.Reasoning? = nil
    var namesUnique = true
    var ignoredHubs: [String] = []
    var nameExamples: [String] = []

    var readRate: Double { ratio(filesRead, filesExpected) }
    var factRate: Double { ratio(factsFound, factsExpected) }
    var entityRecall: Double { ratio(entitiesFound, entitiesExpected) }
    var categoryPurity: Double { ratio(documentsInPureCategory, documentsCategorized) }
    /// Share of the library that reached a real category rather than the holding pen.
    /// Purity without this is gameable by filing nothing.
    var categoryCoverage: Double { ratio(documentsCategorized, filesRead) }
    var citationValidity: Double { citationsStored == 0 ? 1 : ratio(citationsValid, citationsStored) }
    /// 1.0 means every category calls each fact by a single name.
    var schemaCoherence: Double { ratio(fieldUsesOnDominantName, fieldUses) }
    /// Share of understood documents that earned a name from their contents.
    var namedShare: Double { ratio(documentsNamed, documentsUnderstood) }

    private func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 1 : Double(a) / Double(b) }

    /// Thresholds are the contract. Reading is deterministic so it must be near-perfect;
    /// the rest is allowed to degrade with noise, but never to collapse — and citations
    /// must *always* be valid, because a citation that opens nothing destroys trust.
    /// Raised to just under what the pipeline actually achieves, so a regression trips
    /// them rather than being absorbed by slack. The simulator is seeded, so these
    /// numbers are deterministic — there's no flakiness to leave room for.
    ///
    /// Citations are the one that must be perfect. A wrong category is a nuisance a
    /// person can see and correct; a citation that opens nothing is the app lying about
    /// where a fact came from, and there's no recovering trust from that.
    var passed: Bool {
        readRate >= 0.99 && factRate >= 0.98 && citationValidity >= 0.999
            && entityRecall >= 0.90 && sceneryAdmitted == 0
            && brokenFilesHandled == brokenFilesExpected && schemaCoherence >= 0.90
            && namedShare >= 0.90 && namesUnique
            // Clustering is held to less than the rest, and the number is honest rather
            // than flattering. 0.90 was calibrated against the simulator, which names
            // the same entities on the same documents every time; a real model names a
            // slightly different set on each run, and a document's cluster can hinge on
            // one of them. Measured across nine real runs: purity 60–93%, coverage
            // 44–80%. These floors are what held every time, not what looked best once.
            && categoryPurity >= 0.55 && categoryCoverage >= 0.50
            && (reasoning?.passed ?? true)
    }

    func print() {
        let percent = { (value: Double) in String(format: "%3.0f%%", value * 100) }
        Swift.print("\n── model noise \(Int(noise * 100))% " + String(repeating: "─", count: 44))
        Swift.print("  files read          \(percent(readRate))   \(filesRead)/\(filesExpected)")
        Swift.print("  facts preserved     \(percent(factRate))   \(factsFound)/\(factsExpected)")
        Swift.print("  entities found      \(percent(entityRecall))   \(entitiesFound)/\(entitiesExpected)  (\(entityTotal) total, \(String(format: "%.1f", entitiesPerRecord))/record)")
        Swift.print("  scenery kept out    \(sceneryAdmitted == 0 ? " yes" : "  NO")   \(admittedScenery.joined(separator: ", "))")
        Swift.print("  category purity     \(percent(categoryPurity))   \(documentsInPureCategory)/\(documentsCategorized) placed")
        Swift.print("  category coverage   \(percent(categoryCoverage))   \(documentsCategorized)/\(filesRead) filed")
        Swift.print("  citations valid     \(percent(citationValidity))   \(citationsValid)/\(citationsStored)")
        Swift.print("  schema coherence    \(percent(schemaCoherence))   \(fieldUsesOnDominantName)/\(fieldUses) field uses on one name")
        Swift.print("  named from contents \(percent(namedShare))   \(documentsNamed)/\(documentsUnderstood)\(namesUnique ? "" : "  NAMES COLLIDE")")
        Swift.print("  singleton entities  \(percent(singletonShare))")
        Swift.print("  broken files        \(brokenFilesHandled == brokenFilesExpected ? " ok" : " NO")   \(brokenFilesHandled)/\(brokenFilesExpected) failed visibly")
        Swift.print("  categories: " + (categories.isEmpty ? "none"
            : categories.map { "\($0.0) \($0.1)" }.joined(separator: " · ")))
        for line in missedFacts.prefix(6)      { Swift.print("    missed fact:    \(line)") }
        for line in missedEntities.prefix(6)   { Swift.print("    missed entity:  \(line)") }
        for line in impureCategories.prefix(6) { Swift.print("    mixed category: \(line)") }
        for line in splitConcepts.prefix(6)    { Swift.print("    split naming:   \(line)") }
        Swift.print("  entities: " + entityNames.joined(separator: " | "))
        if !ignoredHubs.isEmpty {
            Swift.print("  ignored as hubs: " + ignoredHubs.joined(separator: ", "))
        }
        for line in nameExamples { Swift.print("    named:  \(line)") }

        // Reading documents right is half the job; answering questions about them is the
        // other half, and it's the half a person actually sees.
        if let reasoning {
            Swift.print("\n  ── reasoning over the library " + String(repeating: "─", count: 30))
            Swift.print("  answers correct     \(percent(reasoning.accuracy))   \(reasoning.correct)/\(reasoning.asked)")
            Swift.print("  refused what it can't answer \(percent(reasoning.refusalRate))   \(reasoning.refusalsCorrect)/\(reasoning.refusalsExpected)")
            Swift.print("  citations resolve   \(percent(reasoning.citationValidity))   \(reasoning.citationsValid)/\(reasoning.citationsOffered)")
            if reasoning.uncited > 0 {
                Swift.print("  \(reasoning.uncited) right answer(s) carried no citation")
            }
            for line in reasoning.wrong.prefix(8)  { Swift.print("    \(line)") }
            for line in reasoning.errors.prefix(4) { Swift.print("    ERROR: \(line)") }
        }
        Swift.print("  → \(passed ? "meets thresholds" : "BELOW THRESHOLD")")
    }
}
