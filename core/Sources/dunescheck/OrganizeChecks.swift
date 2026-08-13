import Foundation
import DunesCore

func organizeChecks() async {
    print("\nStage 6 · categories from graph shape")
    await check("records sharing entities land in one cluster", clustersFormFromSharedEntities)
    await check("unconnected records wait in the holding category", loneRecordsHeldBack)
    await check("a category is only born once enough records join it", hysteresis)
    await check("hub entities are ignored so clusters don't collapse", hubsIgnored)
    await check("clustering is stable across runs", stableAcrossRuns)
}

// MARK: - Support

/// Writes a small library where entity membership is controlled exactly, so the
/// clustering can be reasoned about rather than guessed at.
private func seed(_ store: Store, documents: [(name: String, body: String,
                                                category: String?, entities: [String])]) async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ij-org-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let ingest = Ingest(store: store)
    for document in documents {
        let file = folder.appendingPathComponent("\(document.name).md")
        // Entity names must appear in the text or the gate refuses them — which is
        // the behaviour we want everywhere else, so the fixtures respect it.
        let body = "# \(document.name)\n\n\(document.body)\n\n" + document.entities.joined(separator: ", ")
        try body.write(to: file, atomically: true, encoding: .utf8)

        let result = try await ingest.add(fileAt: file)
        let entityJSON = document.entities
            .map { "{\"name\":\"\($0)\",\"kind\":\"org\",\"relation\":\"mentions\"}" }
            .joined(separator: ",")
        let category = document.category.map { "\"category\":\"\($0)\"," } ?? ""
        let provider = ScriptedProvider(json: """
        {"title":"\(document.name)",\(category)"summary":"s","kind":"note",
         "fields":[],"dates":[],"entities":[\(entityJSON)]}
        """)
        _ = try await Distill(store: store, provider: provider)
            .understand(documentID: try require(result.document.id, "id"))
    }
}

private func categories(in store: Store) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for record in try store.records(limit: 500) {
        counts[record.category ?? "—", default: 0] += 1
    }
    return counts
}

// MARK: - Checks

private func clustersFormFromSharedEntities() async throws {
    try await withWorkspace { store in
        // Two groups that share nothing: three about a supplier, three about a clinic.
        try await seed(store, documents: [
            ("invoice one",   "Order placed.", "Finances", ["Alcon Supply"]),
            ("invoice two",   "Order placed.", "Finances", ["Alcon Supply"]),
            ("invoice three", "Order placed.", nil,        ["Alcon Supply"]),
            ("visit one",     "Appointment.",  "Health",   ["Chen Clinic"]),
            ("visit two",     "Appointment.",  "Health",   ["Chen Clinic"]),
            ("visit three",   "Appointment.",  nil,        ["Chen Clinic"]),
        ])

        let outcome = try await DunesCore.Organize(store: store).run()
        await expectEqual(outcome.categories.count, 2, "two clusters, because two groups share nothing")

        let counts = try categories(in: store)
        // The name is a vote: two of three said Finances, so the third joins it —
        // the graph decided membership, the model's guesses decided the label.
        await expectEqual(counts["Finances"], 3, "the unlabelled invoice inherits its cluster's name")
        await expectEqual(counts["Health"], 3, "and likewise for the clinic group")
    }
}

private func loneRecordsHeldBack() async throws {
    try await withWorkspace { store in
        try await seed(store, documents: [
            ("invoice one",   "Order.", "Finances", ["Alcon Supply"]),
            ("invoice two",   "Order.", "Finances", ["Alcon Supply"]),
            ("invoice three", "Order.", "Finances", ["Alcon Supply"]),
            ("stray note",    "Nothing to do with anything.", "Musings", ["Zeta Holdings"]),
        ])

        _ = try await DunesCore.Organize(store: store).run()
        let counts = try categories(in: store)
        await expectEqual(counts["Finances"], 3, "the connected group is a category")
        await expectEqual(counts[DunesCore.Organize.holdingCategory], 1,
                          "the unconnected record waits rather than minting a category of one")
    }
}

private func hysteresis() async throws {
    try await withWorkspace { store in
        // Two related records isn't a pattern yet.
        try await seed(store, documents: [
            ("trip one", "Flight.", "Travel", ["Skyline Air"]),
            ("trip two", "Hotel.",  "Travel", ["Skyline Air"]),
            ("odd one",  "Unrelated.", nil,   ["Quiet Corp"]),
        ])
        _ = try await DunesCore.Organize(store: store).run()
        await expect(try categories(in: store)["Travel"] == nil,
                     "two records don't yet earn a category")

        // A third joins, and Travel is born already correct.
        try await seed(store, documents: [
            ("trip three", "Car hire.", "Travel", ["Skyline Air"]),
        ])
        _ = try await DunesCore.Organize(store: store).run()
        await expectEqual(try categories(in: store)["Travel"], 3,
                          "the third arrival brings the category into being")
    }
}

private func hubsIgnored() async throws {
    try await withWorkspace { store in
        // "City Council" touches everything. Left in the graph it would wire the two
        // groups together and collapse them into a single meaningless cluster.
        try await seed(store, documents: [
            ("invoice one",   "Order.", "Finances", ["Alcon Supply", "City Council"]),
            ("invoice two",   "Order.", "Finances", ["Alcon Supply", "City Council"]),
            ("invoice three", "Order.", "Finances", ["Alcon Supply", "City Council"]),
            ("visit one",     "Visit.", "Health",   ["Chen Clinic", "City Council"]),
            ("visit two",     "Visit.", "Health",   ["Chen Clinic", "City Council"]),
            ("visit three",   "Visit.", "Health",   ["Chen Clinic", "City Council"]),
        ])

        let outcome = try await DunesCore.Organize(store: store).run()
        await expect(outcome.ignoredHubs.contains { $0.contains("City Council") },
                     "the over-connected entity is identified as a hub")
        await expectEqual(outcome.categories.count, 2,
                          "and the two real groups stay separate despite it")
    }
}

private func stableAcrossRuns() async throws {
    try await withWorkspace { store in
        try await seed(store, documents: [
            ("a", "One.",   "Finances", ["Alcon Supply"]),
            ("b", "Two.",   "Finances", ["Alcon Supply"]),
            ("c", "Three.", "Finances", ["Alcon Supply"]),
            ("d", "Four.",  "Health",   ["Chen Clinic"]),
            ("e", "Five.",  "Health",   ["Chen Clinic"]),
            ("f", "Six.",   "Health",   ["Chen Clinic"]),
        ])

        // A category list that reshuffled on every pass would be worse than a
        // slightly worse one that stays put, so ties break deterministically.
        _ = try await DunesCore.Organize(store: store).run()
        let first = try categories(in: store)
        _ = try await DunesCore.Organize(store: store).run()
        let second = try categories(in: store)
        await expectEqual(first, second, "running twice gives the same answer")
    }
}

/// Found by a real run: clustering was reading back its own previous answer as if it
/// were the model's independent opinion.
func categoryEvidenceChecks() async {
    print("\nCategories · the evidence outlives the conclusion")
    await check("clustering never overwrites the model's own guess", hintSurvivesClustering)
    await check("a category needs more than one document's say-so", oneVoteIsNotAVote)
}

private func hintSurvivesClustering() async throws {
    try await withWorkspace { store in
        try await seed(store, documents: [
            ("t1", "Flight.",   "Travel", ["Skyline Air"]),
            ("t2", "Hotel.",    "Travel", ["Skyline Air"]),
            ("t3", "Car hire.", "Travel", ["Skyline Air"]),
        ])
        // Before clustering, the guess and the filing are the same thing.
        let before = try store.records(limit: 10)
        await expect(before.allSatisfy { $0.categoryHint == "Travel" }, "each document's guess is stored")

        _ = try await DunesCore.Organize(store: store).run()
        let after = try store.records(limit: 10)

        await expect(after.allSatisfy { $0.categoryHint == "Travel" },
                     "and it still says Travel after the graph has filed them")
        await expect(after.allSatisfy { $0.category == "Travel" }, "which is also where they're filed")

        // The failure this pins: run clustering twice and the votes must not have
        // become our own output. Nothing about the second pass should differ.
        _ = try await DunesCore.Organize(store: store).run()
        let twice = try store.records(limit: 10)
        await expect(twice.allSatisfy { $0.categoryHint == "Travel" },
                     "a second pass still counts the model's reading, not its own last answer")
        await expect(twice.allSatisfy { $0.category == "Travel" }, "so the filing is stable")
    }
}

private func oneVoteIsNotAVote() async throws {
    try await withWorkspace { store in
        // A real run named thirteen documents "spending_report" because one spreadsheet
        // said so and nothing else agreed.
        try await seed(store, documents: [
            ("a", "Shared vendor.", "spending_report", ["Alcon Laboratories"]),
            ("b", "Shared vendor.", nil,               ["Alcon Laboratories"]),
            ("c", "Shared vendor.", nil,               ["Alcon Laboratories"]),
        ])
        _ = try await DunesCore.Organize(store: store).run()
        let names = Set(try store.records(limit: 10).compactMap(\.category))
        await expect(!names.contains("spending_report"),
                     "one document's opinion doesn't name the cluster it's in")
    }
}

func shelfNameChecks() async {
    print("\nOrganize · a shelf label a person would accept")
    await check("plurals are spelt, not concatenated", pluralsAreSpelt)
}

private func pluralsAreSpelt() async throws {
    // The one that shipped: a library of insurance documents filed under "Policys".
    await expectEqual(Organize.plural(of: "policy"), "policies", "consonant before y")
    await expectEqual(Organize.plural(of: "statement"), "statements", "the ordinary case")
    await expectEqual(Organize.plural(of: "invoice"), "invoices", "already ends in a vowel")
    await expectEqual(Organize.plural(of: "receipt"), "receipts", "and the plain one")
    // A vowel before the y keeps it: journeys, not journies.
    await expectEqual(Organize.plural(of: "survey"), "surveys", "vowel before y")
}
