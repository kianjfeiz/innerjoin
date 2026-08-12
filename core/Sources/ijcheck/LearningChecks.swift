import Foundation
import InnerjoinCore

func learningChecks() async {
    print("\nLearning · the library teaches itself")
    await check("a category's field names are fed back into the prompt", vocabularyIsFedBack)
    await check("a worked example from the category is shown", exemplarIsShown)
    await check("nothing is fed back when there's nothing learned yet", coldStartIsClean)
    await check("re-reading is offered only to documents that disagree with peers", divergenceIsDetected)
    await check("re-reading raises agreement and then stops", refinementConverges)
}

/// A provider that records the prompt it was given and answers with whatever field
/// name it was told to use — the same in-context behaviour a real model has, made
/// observable.
final class PromptSpy: ModelProvider, @unchecked Sendable {
    private(set) var lastSystem = ""
    let respondWith: @Sendable (String) -> String
    var label: String { "Spy" }

    init(respondWith: @escaping @Sendable (String) -> String) {
        self.respondWith = respondWith
    }

    func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data {
        lastSystem = system
        return Data(respondWith(system).utf8)
    }
}

private func plainReply(_ fieldName: String) -> String {
    """
    {"title":"Doc","summary":"s","category":"Supplies","kind":"invoice",
     "fields":[{"name":"\(fieldName)","value":"$100.00","source":"e0"}],
     "dates":[],"entities":[]}
    """
}

/// Builds a small library where several records already agree on a field name.
private func seedNaming(_ store: Store, name: String, copies: Int) async throws -> [Int64] {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ij-learn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    var ids: [Int64] = []
    let ingest = Ingest(store: store)
    for index in 0..<copies {
        let file = folder.appendingPathComponent("invoice\(index).md")
        try "# Office supplies invoice \(index)\n\nTotal due $100.00 from Alcon Laboratories."
            .write(to: file, atomically: true, encoding: .utf8)
        let result = try await ingest.add(fileAt: file)
        let id = try require(result.document.id, "id")
        ids.append(id)
        let provider = PromptSpy { _ in plainReply(name) }
        _ = try await Distill(store: store, provider: provider).understand(documentID: id)
    }
    return ids
}

// MARK: -

private func vocabularyIsFedBack() async throws {
    try await withWorkspace { store in
        _ = try await seedNaming(store, name: "total_due", copies: 3)

        // A fourth document of the same kind should be read knowing what the first
        // three settled on — that feedback is the whole of innerjoin's "training".
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("invoice_new.md")
        try "# Invoice 4\n\nTotal due $250.00 from Alcon Laboratories."
            .write(to: file, atomically: true, encoding: .utf8)
        let result = try await Ingest(store: store).add(fileAt: file)

        let spy = PromptSpy { _ in plainReply("total_due") }
        _ = try await Distill(store: store, provider: spy)
            .understand(documentID: try require(result.document.id, "id"))

        await expect(spy.lastSystem.contains("KNOWN FIELD NAMES"),
                     "the prompt carries the names already in use")
        await expect(spy.lastSystem.contains("total_due"),
                     "including the one this category settled on")
    }
}

private func exemplarIsShown() async throws {
    try await withWorkspace { store in
        _ = try await seedNaming(store, name: "total_due", copies: 3)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("invoice_show.md")
        try "# Office supplies invoice 9\n\nTotal due $9.00 from Alcon Laboratories."
            .write(to: file, atomically: true, encoding: .utf8)
        let result = try await Ingest(store: store).add(fileAt: file)

        let spy = PromptSpy { _ in plainReply("total_due") }
        _ = try await Distill(store: store, provider: spy)
            .understand(documentID: try require(result.document.id, "id"))

        // One worked example teaches more about what a good reading of this kind of
        // document looks like than another paragraph of instructions.
        await expect(spy.lastSystem.contains("A previous document of this kind"),
                     "a prior record is shown as an example")
    }
}

private func coldStartIsClean() async throws {
    try await withWorkspace { store in
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("first.md")
        try "# First\n\nNothing has been read before this."
            .write(to: file, atomically: true, encoding: .utf8)
        let result = try await Ingest(store: store).add(fileAt: file)

        let spy = PromptSpy { _ in plainReply("total_due") }
        _ = try await Distill(store: store, provider: spy)
            .understand(documentID: try require(result.document.id, "id"))

        // An empty library must not pad the prompt with empty scaffolding.
        await expect(!spy.lastSystem.contains("KNOWN FIELD NAMES"),
                     "no vocabulary block when nothing has been learned")
        await expect(!spy.lastSystem.contains("A previous document of this kind"),
                     "and no example block either")
    }
}

private func divergenceIsDetected() async throws {
    try await withWorkspace { store in
        // Three records agree; one calls the same fact something else. Only the odd
        // one out is worth spending a second read on.
        _ = try await seedNaming(store, name: "total_due", copies: 3)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("odd_one.md")
        try "# Office supplies invoice odd\n\nTotal due $77.00 from Alcon Laboratories."
            .write(to: file, atomically: true, encoding: .utf8)
        let result = try await Ingest(store: store).add(fileAt: file)
        let oddID = try require(result.document.id, "id")
        _ = try await Distill(store: store, provider: PromptSpy { _ in plainReply("invoice_total") })
            .understand(documentID: oddID)

        let refine = Refine(store: store, provider: MockProvider())
        let divergent = try refine.divergentRecords()
        await expect(divergent.contains { $0.documentID == oddID },
                     "the record that names things differently is picked out")
        await expectEqual(divergent.count, 1, "and the ones that agree are left alone")
    }
}

private func refinementConverges() async throws {
    try await withWorkspace { store in
        _ = try await seedNaming(store, name: "total_due", copies: 3)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("stray.md")
        try "# Office supplies invoice stray\n\nTotal due $12.00 from Alcon Laboratories."
            .write(to: file, atomically: true, encoding: .utf8)
        let result = try await Ingest(store: store).add(fileAt: file)
        _ = try await Distill(store: store, provider: PromptSpy { _ in plainReply("amount_due") })
            .understand(documentID: try require(result.document.id, "id"))

        // A model that honours the vocabulary it's given, as a real one does.
        let obedient = PromptSpy { system in
            plainReply(system.contains("total_due") ? "total_due" : "amount_due")
        }
        let refine = Refine(store: store, provider: obedient)
        let before = try refine.coherence()
        let passes = try await refine.run()
        let after = try refine.coherence()

        await expect(!passes.isEmpty, "there was something to settle")
        await expect(after > before, "re-reading raises agreement (\(Int(before * 100))% → \(Int(after * 100))%)")

        // And it must know when to stop rather than churning the library forever.
        let secondRound = try await refine.run()
        await expect(secondRound.isEmpty, "a settled library is left alone")
    }
}
