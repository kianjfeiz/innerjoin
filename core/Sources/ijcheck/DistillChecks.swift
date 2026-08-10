import Foundation
import InnerjoinCore

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

        // The model reports the notice period; innerjoin does the subtraction itself.
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
