import Foundation
import InnerjoinCore

func consolidateChecks() async {
    print("\nStage 4 · tidying the graph")
    await check("a short form folds into the full name", shortFormsMerge)
    await check("similar-but-different names stay apart", nearMissesStayApart)
    await check("merging moves the edges, not just the name", mergeMovesLinks)
    await check("people and companies never merge with each other", kindsDontCross)
    await check("two documents disagreeing becomes a flag", conflictsAreFlagged)
    await check("the same value formatted differently isn't a conflict", formattingIsNotConflict)
}

// MARK: - Matching

private func shortFormsMerge() async throws {
    // The common real case: a vendor written in full on the invoice and abbreviated
    // in an email six months later.
    await expect(Consolidate.sameThing("alcon laboratories", "alcon") != nil,
                 "an organization's short form is recognized")
    await expect(Consolidate.sameThing("state farm insurance", "state farm") != nil,
                 "two words of three is enough")
}

private func nearMissesStayApart() async throws {
    // A wrong merge silently fuses two people's records, so the bar is deliberately
    // high — a duplicate a human can spot beats a merge nobody notices.
    await expect(Consolidate.sameThing("anna", "ann") == nil,
                 "a prefix that isn't a whole word doesn't merge")
    await expect(Consolidate.sameThing("m osei", "m oseni") == nil,
                 "similar surnames stay separate")
    await expect(Consolidate.sameThing("acme west", "acme east") == nil,
                 "a shared first word isn't enough")
}

private func kindsDontCross() async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        let lease = try await ingest.add(fileAt: try fixture("lease.pdf"))

        // Same name, different kinds. This once asserted the two stayed separate, on the
        // reasoning that a company named after its founder is not the founder. Real runs
        // overruled it: the model labels one organization `org`, then `place`, then
        // `person` across three documents, and each label minted another node — so the
        // documents that should have clustered together didn't, and a third of the
        // library sat unfiled. One name is now one node. The cost is a dossier that can
        // merge a founder with their company; the benefit is a graph that connects.
        let provider = ScriptedProvider(json: """
        {"title":"t","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"M. Osei","kind":"person","relation":"party_to"},
                     {"name":"M. Osei","kind":"org","relation":"issued_by"}]}
        """)
        _ = try await Distill(store: store, provider: provider)
            .understand(documentID: try require(lease.document.id, "id"))
        _ = try await Consolidate(store: store).run()

        await expectEqual(try store.entities().count, 1, "one name is one node, whatever it's labelled")

        // Everything else with one name is one thing. Measured, not assumed: a real run
        // stored Chen Clinic, State Farm and PG&E twice each because the model called
        // them `org` on one document and `place` on the next, and the documents that
        // should have clustered together didn't.
        let second = try await ingest.add(fileAt: try fixture("receipt.png"))
        let asPlace = ScriptedProvider(json: """
        {"title":"t","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"M. Osei","kind":"place","relation":"located_at"}]}
        """)
        _ = try await Distill(store: store, provider: asPlace)
            .understand(documentID: try require(second.document.id, "id"))
        await expectEqual(try store.entities().count, 1,
                          "and a later, different label doesn't mint another")
    }
}

// MARK: - Merging

private func mergeMovesLinks() async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        // Both of these genuinely name Alcon, so the entity gate admits them. (Using a
        // document that didn't mention the company would — correctly — get it refused.)
        let first = try await ingest.add(fileAt: try fixture("receipt.png"))
        let second = try await ingest.add(fileAt: try fixture("scanned_receipt.pdf"))

        // Ingest can only match against what it knew at the time, so these arrive as
        // two entities. The tidy pass is what notices later.
        _ = try await Distill(store: store, provider: ScriptedProvider(json: """
        {"title":"Invoice","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"Alcon Laboratories","kind":"org","relation":"issued_by"}]}
        """)).understand(documentID: try require(first.document.id, "id"))

        _ = try await Distill(store: store, provider: ScriptedProvider(json: """
        {"title":"Scan of the same invoice","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"Alcon","kind":"org","relation":"issued_by"}]}
        """)).understand(documentID: try require(second.document.id, "id"))

        await expectEqual(try store.entities().count, 2, "they start out separate")

        let outcome = try await Consolidate(store: store).run()
        await expectEqual(try store.entities().count, 1, "and end up as one")
        await expect(!outcome.merged.isEmpty, "the merge is reported")

        // The point of merging: both documents now hang off the same node.
        let survivor = try require(try store.entities().first, "the surviving entity")
        await expectEqual(survivor.name, "Alcon Laboratories", "the fuller name survives")
        await expect(survivor.aliases.contains("Alcon"), "the short form is kept as an alias")
        await expectEqual(try store.records(linkedTo: try require(survivor.id, "id")).count, 2,
                          "both records are attached to it")
    }
}

// MARK: - Conflicts

private func conflictsAreFlagged() async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        let original = try await ingest.add(fileAt: try fixture("lease.pdf"))
        let amendment = try await ingest.add(fileAt: try fixture("notes.md"))

        // The lease says two months; the later note says one. This is the case the
        // whole product is named for — and neither value gets overwritten.
        _ = try await Distill(store: store, provider: ScriptedProvider(json: """
        {"title":"Lease","summary":"s","happened_on":"2024-03-14",
         "fields":[{"name":"break_penalty","value":"2 months rent","source":"e0"}],
         "dates":[],"entities":[{"name":"M. Osei","kind":"person","relation":"party_to"}]}
        """)).understand(documentID: try require(original.document.id, "id"))

        _ = try await Distill(store: store, provider: ScriptedProvider(json: """
        {"title":"Amendment","summary":"s","happened_on":"2026-03-12",
         "fields":[{"name":"break_penalty","value":"1 month rent","source":"e0"}],
         "dates":[],"entities":[{"name":"M. Osei","kind":"person","relation":"party_to"}]}
        """)).understand(documentID: try require(amendment.document.id, "id"))

        let outcome = try await Consolidate(store: store).run()
        let conflict = try require(outcome.conflicts.first { $0.field == "break_penalty" },
                                   "a flagged disagreement")
        await expectEqual(conflict.newer.value, "1 month rent", "the later document is the newer side")
        await expectEqual(conflict.older.value, "2 months rent", "the original is kept, not overwritten")

        // Recorded as an edge, so the UI can show it without recomputing.
        let newerRecord = try require(try store.record(ofDocument:
            try require(amendment.document.id, "id")), "the newer record")
        let links = try store.links(from: try require(newerRecord.id, "id"))
        await expect(links.contains { $0.rel == "contradicts" }, "the disagreement is on the graph")
    }
}

private func formattingIsNotConflict() async throws {
    // Flagging "$3,200.00" against "3200" would train people to ignore flags.
    await expectEqual(Consolidate.comparable("$3,200.00"), Consolidate.comparable("3200"),
                      "currency formatting is ignored")
    await expectEqual(Consolidate.comparable(" Two Months "), Consolidate.comparable("two months"),
                      "case and spacing are ignored")
    await expect(Consolidate.comparable("1 month") != Consolidate.comparable("2 months"),
                 "a real difference still reads as different")
}

/// From a real run: the same organization stored twice because the model labelled it
/// differently on two documents, which quietly severed the link between them.
func entityIdentityChecks() async {
    print("\nEntities · one thing, one node")
    await check("the same name under two kinds is one entity", sameNameOneEntity)
}

private func sameNameOneEntity() async throws {
    try await withWorkspace { store in
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let ingest = Ingest(store: store)
        for (index, kind) in ["org", "place"].enumerated() {
            let file = folder.appendingPathComponent("visit\(index).md")
            try "# Visit \(index)\n\nSeen at Chen Clinic today.".write(to: file, atomically: true,
                                                                     encoding: .utf8)
            let added = try await ingest.add(fileAt: file)
            let provider = ScriptedProvider(json: """
            {"title":"Visit \(index)","summary":"s","fields":[],"dates":[],
             "entities":[{"name":"Chen Clinic","kind":"\(kind)","relation":"party_to"}]}
            """)
            _ = try await Distill(store: store, provider: provider)
                .understand(documentID: try require(added.document.id, "id"))
        }

        let clinics = try store.entities(limit: 50).filter { $0.name == "Chen Clinic" }
        await expectEqual(clinics.count, 1,
                          "a clinic called an org once and a place once is still one clinic")

        // The point isn't tidiness — it's that both documents now hang off the same node,
        // which is what lets them cluster together at all.
        let entityID = try require(clinics.first?.id, "the entity")
        await expectEqual(try store.records(linkedTo: entityID).count, 2,
                          "so both documents are tied to it")
    }
}
