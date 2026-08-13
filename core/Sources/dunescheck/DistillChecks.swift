import Foundation
import DunesCore

/// A provider that returns exactly the JSON a check hands it, so the validation paths
/// can be exercised without a network or a key.
struct ScriptedProvider: ModelProvider {
    let json: String
    var label: String { "Scripted" }
    func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data {
        Data(json.utf8)
    }
}

func distillChecks() async {
    print("\nStage 3 · distill")
    await check("a document becomes a record with provenance", recordHasProvenance)
    await check("invented citations are dropped, not stored", inventedCitationsDropped)
    await check("understanding twice replaces rather than duplicates", reRunReplaces)
    await check("the same name in two files resolves to one entity", entitiesMerge)
    await check("corporate suffixes and punctuation don't split an entity", entityNormalization)
    await check("implausible dates are refused", implausibleDates)
    await check("a notice deadline is worked out, not asked for", derivedDeadline)
    await check("a provider failure leaves the document searchable", providerFailureIsSurvivable)

    await check("search reaches what was understood, not just the text", searchReachesRecords)

    print("\nStage 3 · keeping the graph clean")
    await check("invented entities are refused", inventedEntitiesRefused)
    await check("roles and broad places are refused, real parties aren't", scenerRefused)
    await check("a flood of entities is capped", entityFloodCapped)
    await check("relations stay in the known vocabulary", relationVocabulary)
    await check("graph health reports singletons and hubs", graphHealthReports)
}

// MARK: -

private func recordHasProvenance() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")
        _ = try await Distill(store: store, provider: MockProvider()).understand(documentID: documentID)

        let record = try require(try store.record(ofDocument: documentID), "a record")
        await expect(!record.title.isEmpty, "the record is titled")
        await expect(!record.fields.isEmpty, "it carries fields")

        // The whole citation chain: a field knows the element, page, and box it came from.
        let located = record.fields.values.filter { $0.page != nil && $0.box != nil }
        await expect(!located.isEmpty, "at least one field resolves to a page and a box")
        for field in record.fields.values where field.source != nil {
            await expect(field.page != nil, "a cited field carries its page")
        }
    }
}

private func inventedCitationsDropped() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")

        // "e9999" doesn't exist on this document. Storing it would produce a citation
        // that opens nothing — the one failure that would quietly destroy trust.
        let provider = ScriptedProvider(json: """
        {"title":"Lease","summary":"s",
         "fields":[{"name":"real","value":"yes","source":"e0"},
                   {"name":"fake","value":"no","source":"e9999"}],
         "dates":[],"entities":[]}
        """)
        let outcome = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        await expectEqual(outcome.droppedCitations, 1, "the invented citation is counted")
        let record = try require(try store.record(ofDocument: documentID), "a record")
        await expect(record.fields["real"]?.source == "e0", "the real citation survives")
        await expect(record.fields["fake"]?.source == nil, "the invented one is stored without provenance")
        await expect(record.fields["fake"] != nil, "but the value itself is kept")
    }
}

private func reRunReplaces() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("notes.md"))
        let documentID = try require(result.document.id, "document id")
        let distill = Distill(store: store, provider: MockProvider())

        _ = try await distill.understand(documentID: documentID)
        _ = try await distill.understand(documentID: documentID)

        let records = try store.records(limit: 100).filter { $0.documentID == documentID }
        await expectEqual(records.count, 1, "one document still has exactly one record")
    }
}

private func entitiesMerge() async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        let lease = try await ingest.add(fileAt: try fixture("lease.pdf"))
        let notes = try await ingest.add(fileAt: try fixture("notes.md"))

        let provider = ScriptedProvider(json: """
        {"title":"t","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"M. Osei","kind":"person","relation":"party_to"}]}
        """)
        let distill = Distill(store: store, provider: provider)
        _ = try await distill.understand(documentID: try require(lease.document.id, "id"))
        _ = try await distill.understand(documentID: try require(notes.document.id, "id"))

        let people = try store.entities().filter { $0.kind == .person }
        await expectEqual(people.count, 1, "the landlord is one entity, not two")

        // And that entity now connects both documents — the join, in miniature.
        let linked = try store.records(linkedTo: try require(people.first?.id, "entity id"))
        await expectEqual(linked.count, 2, "both records hang off it")
    }
}

private func entityNormalization() async throws {
    await expectEqual(Entity.normalize("Alcon Laboratories, Inc."),
                      Entity.normalize("alcon laboratories"),
                      "a corporate suffix doesn't create a second company")
    await expectEqual(Entity.normalize("PG&E"), Entity.normalize("PG&E, Inc."),
                      "punctuation and suffixes are ignored when matching")
    await expectEqual(Entity.normalize("  M.  OSEI "), Entity.normalize("m. osei"),
                      "case and spacing don't split an entity")
    await expect(Entity.normalize("M. Osei") != Entity.normalize("M. Oseni"),
                 "genuinely different names stay different")
}

private func implausibleDates() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("notes.md"))
        let documentID = try require(result.document.id, "document id")

        // A misparsed year would otherwise surface as a deadline in someone's briefing.
        let provider = ScriptedProvider(json: """
        {"title":"t","summary":"s","fields":[],
         "dates":[{"kind":"term_end","date":"2027-03-31"},
                  {"kind":"nonsense","date":"0007-01-01"},
                  {"kind":"unparseable","date":"next Tuesday"}],
         "entities":[]}
        """)
        _ = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        let record = try require(try store.record(ofDocument: documentID), "a record")
        let dates = try store.dates(ofRecord: try require(record.id, "record id"))
        await expectEqual(dates.count, 1, "only the plausible, parseable date is kept")
        await expectEqual(dates.first?.kind, "term_end", "and it's the right one")
    }
}

private func derivedDeadline() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")

        // The model reports the notice period; dunes does the subtraction itself.
        let provider = ScriptedProvider(json: """
        {"title":"Lease","summary":"s","notice_days":60,"fields":[],
         "dates":[{"kind":"term_end","date":"2027-03-31"}],"entities":[]}
        """)
        _ = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        let record = try require(try store.record(ofDocument: documentID), "a record")
        let dates = try store.dates(ofRecord: try require(record.id, "record id"))
        let deadline = try require(dates.first { $0.kind == "notice_deadline" }, "a derived deadline")
        await expect(deadline.derived, "it's marked as worked out, not stated")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        await expectEqual(formatter.string(from: deadline.date), "2027-01-30",
                          "60 days before the term ends")
    }
}

private func searchReachesRecords() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")

        // "Tenancy" appears nowhere in the file — only in what the model made of it.
        // ⌘K exists to query understanding, so understanding has to be indexed.
        let provider = ScriptedProvider(json: """
        {"title":"Tenancy at Fillmore","summary":"A residential tenancy.",
         "category":"Apartment","fields":[],"dates":[],"entities":[]}
        """)
        _ = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        await expect(try store.search("Tenancy").isEmpty,
                     "the word is genuinely absent from the document text")
        let hits = try store.find("Tenancy")
        await expect(!hits.isEmpty, "but searching finds it through the record")
        await expect(hits.first?.matchedRecord == true, "and says the match came from understanding")
        await expectEqual(hits.first?.document.name, "lease.pdf", "pointing back at the right file")
    }
}

// MARK: - Keeping the graph clean
//
// Over-production is the quiet failure: nothing errors, the graph just fills with
// nodes that mean nothing, and Stage 6's clustering degrades into one blob.

private func inventedEntitiesRefused() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")

        // "Wayne Enterprises" is nowhere in this lease. A name absent from the text
        // was invented, and no amount of confidence should get it onto the graph.
        let provider = ScriptedProvider(json: """
        {"title":"Lease","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"M. Osei","kind":"person","relation":"party_to"},
                     {"name":"Wayne Enterprises","kind":"org","relation":"party_to"}]}
        """)
        let outcome = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        await expectEqual(outcome.entityCount, 1, "only the real party is admitted")
        await expect(outcome.refusedEntities.contains { $0.contains("Wayne") },
                     "and the invented one is reported, not silently dropped")
        let names = try store.entities().map(\.name)
        await expect(!names.contains("Wayne Enterprises"), "it never reaches the graph")
    }
}

private func scenerRefused() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")

        let provider = ScriptedProvider(json: """
        {"title":"Lease","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"M. Osei","kind":"person","relation":"party_to"},
                     {"name":"Tenant","kind":"person","relation":"party_to"},
                     {"name":"San Francisco","kind":"place","relation":"located_at"},
                     {"name":"CA","kind":"place","relation":"located_at"},
                     {"name":"1247 Fillmore St","kind":"place","relation":"governs"}]}
        """)
        let outcome = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        let names = try store.entities().map(\.name)
        await expect(names.contains("M. Osei"), "a named party is kept")
        // A street address is a subject you can hold a lease on; a city is a hub.
        await expect(names.contains("1247 Fillmore St"), "a specific address is kept")
        await expect(!names.contains("Tenant"), "a role is refused")
        await expect(!names.contains("San Francisco"), "a city is refused")
        await expect(!names.contains("CA"), "a state is refused")
        await expectEqual(outcome.entityCount, 2, "two survive of five proposed")
    }
}

private func entityFloodCapped() async throws {
    try await withWorkspace { store in
        // Every name here appears in the document, so only the cap can stop them.
        let markdown = (1...40).map { "Party Number \($0) signed the agreement." }.joined(separator: "\n\n")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-flood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("crowd.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try await Ingest(store: store).add(fileAt: file)
        let documentID = try require(result.document.id, "document id")

        let entities = (1...40).map {
            "{\"name\":\"Party Number \($0)\",\"kind\":\"org\",\"relation\":\"party_to\"}"
        }.joined(separator: ",")
        let provider = ScriptedProvider(json: """
        {"title":"Crowd","summary":"s","fields":[],"dates":[],"entities":[\(entities)]}
        """)
        let outcome = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        await expect(outcome.entityCount <= EntityGate.perDocumentLimit,
                     "the per-document limit holds at \(EntityGate.perDocumentLimit)")
        await expect(!outcome.refusedEntities.isEmpty, "the overflow is reported")
    }
}

private func relationVocabulary() async throws {
    // The schema pins the enum, so a compliant provider can't invent predicates. This
    // check guards the fallback path: anything unexpected becomes `mentions` rather
    // than a new relation nobody will ever query.
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")

        let provider = ScriptedProvider(json: """
        {"title":"Lease","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"M. Osei","kind":"person","relation":""}]}
        """)
        _ = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        let record = try require(try store.record(ofDocument: documentID), "a record")
        let links = try store.links(from: try require(record.id, "record id"))
        await expectEqual(links.first?.rel, "mentions", "an empty relation falls back to mentions")
    }
}

private func graphHealthReports() async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        let lease = try await ingest.add(fileAt: try fixture("lease.pdf"))
        let notes = try await ingest.add(fileAt: try fixture("notes.md"))

        // Osei is in both files; the notary is in one. One recurs, one doesn't —
        // which is exactly what the singleton count is for.
        let both = ScriptedProvider(json: """
        {"title":"t","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"M. Osei","kind":"person","relation":"party_to"}]}
        """)
        let distill = Distill(store: store, provider: both)
        _ = try await distill.understand(documentID: try require(lease.document.id, "id"))
        _ = try await distill.understand(documentID: try require(notes.document.id, "id"))

        let health = try store.graphHealth()
        await expectEqual(health.records, 2, "both records counted")
        await expectEqual(health.entities, 1, "one entity across both")
        await expectEqual(health.singletons, 0, "an entity in two files isn't a singleton")
        await expect(health.relations.contains { $0.name == "party_to" },
                     "relations are broken down by kind")
    }
}

private func providerFailureIsSurvivable() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")

        let broken = ScriptedProvider(json: "this is not json at all")
        var threw = false
        do { _ = try await Distill(store: store, provider: broken).understand(documentID: documentID) }
        catch { threw = true }
        await expect(threw, "a malformed reply is reported")

        // Degrading in layers: no record, but the document keeps its markdown and
        // stays findable. Understanding is an upgrade, never a prerequisite.
        let document = try require(try store.document(id: documentID), "the document")
        await expect(document.markdown?.isEmpty == false, "the markdown survives")
        await expect(try !store.search("Fillmore").isEmpty, "and it's still searchable")
    }
}


