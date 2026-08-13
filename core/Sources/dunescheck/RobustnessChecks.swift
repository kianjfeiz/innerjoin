import Foundation
import DunesCore

func robustnessChecks() async {
    print("\nRedundancy · the same input twice, and re-running stages")
    await check("re-adding a whole folder changes nothing", folderIsIdempotent)
    await check("re-reading a document produces the same elements", parsingIsDeterministic)
    await check("re-understanding replaces cleanly, leaving no orphans", understandingIsIdempotent)
    await check("tidying twice is the same as tidying once", tidyIsIdempotent)
    await check("sorting twice is the same as sorting once", sortIsIdempotent)
    await check("a partly-understood library can be finished later", backlogResumes)

    print("\nRedundancy · the gate holds its ground")
    await check("role nouns are refused however they're built", roleNouns)
    await check("paperwork words never become entities", paperworkNouns)
    await check("short forms merge, lookalikes still don't", shortFormBoundary)
}

// MARK: - Idempotency
//
// Ingestion runs repeatedly in real use — a watch folder re-scans, a user re-drops a
// download. Anything that accumulates on a second pass corrupts the library slowly,
// which is the hardest kind of bug to notice.

private func folderIsIdempotent() async throws {
    try await withWorkspace { store in
        let folder = try fixture("lease.pdf").deletingLastPathComponent()
        let ingest = Ingest(store: store)

        _ = try await ingest.addContents(of: folder)
        let first = try store.counts()
        _ = try await ingest.addContents(of: folder)
        let second = try store.counts()

        await expectEqual(second.documents, first.documents, "no new documents on a second pass")
        await expectEqual(second.elements, first.elements, "and no duplicated elements")
    }
}

private func parsingIsDeterministic() async throws {
    try await withWorkspace { storeA in
        try await withWorkspace { storeB in
            let file = try fixture("lease.pdf")
            let a = try await Ingest(store: storeA).add(fileAt: file)
            let b = try await Ingest(store: storeB).add(fileAt: file)

            let left = try storeA.elements(of: try require(a.document.id, "id"))
            let right = try storeB.elements(of: try require(b.document.id, "id"))
            await expectEqual(left.count, right.count, "the same file yields the same element count")
            await expectEqual(left.map(\.text), right.map(\.text), "and the same text, in the same order")
            await expectEqual(a.document.markdown, b.document.markdown, "and an identical rendition")
        }
    }
}

private func understandingIsIdempotent() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let id = try require(result.document.id, "id")
        let provider = ScriptedProvider(json: """
        {"title":"Lease","summary":"s","fields":[{"name":"rent","value":"$3,200.00","source":"e0"}],
         "dates":[{"kind":"term_end","date":"2027-03-31"}],
         "entities":[{"name":"M. Osei","kind":"person","relation":"party_to"}]}
        """)
        let distill = Distill(store: store, provider: provider)
        _ = try await distill.understand(documentID: id)
        _ = try await distill.understand(documentID: id)
        _ = try await distill.understand(documentID: id)

        let record = try require(try store.record(ofDocument: id), "a record")
        await expectEqual(try store.records(limit: 100).count, 1, "still one record")
        // Dates and links hang off the record; if the record is replaced without them
        // being cleared, they pile up invisibly on every re-run.
        await expectEqual(try store.dates(ofRecord: try require(record.id, "id")).count, 1,
                          "dates don't accumulate")
        await expectEqual(try store.links(from: try require(record.id, "id")).count, 1,
                          "nor do links")
        await expectEqual(try store.entities().count, 1, "and the entity isn't duplicated")
    }
}

private func tidyIsIdempotent() async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        let a = try await ingest.add(fileAt: try fixture("receipt.png"))
        let b = try await ingest.add(fileAt: try fixture("scanned_receipt.pdf"))
        _ = try await Distill(store: store, provider: ScriptedProvider(json: """
        {"title":"t","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"Alcon Laboratories","kind":"org","relation":"issued_by"}]}
        """)).understand(documentID: try require(a.document.id, "id"))
        _ = try await Distill(store: store, provider: ScriptedProvider(json: """
        {"title":"t","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"Alcon","kind":"org","relation":"issued_by"}]}
        """)).understand(documentID: try require(b.document.id, "id"))

        let consolidate = Consolidate(store: store)
        let first = try await consolidate.run()
        let entitiesAfterFirst = try store.entities().count
        let second = try await consolidate.run()

        await expect(!first.merged.isEmpty, "the first pass merges the duplicate")
        await expect(second.merged.isEmpty, "the second finds nothing left to merge")
        await expectEqual(try store.entities().count, entitiesAfterFirst, "and changes nothing")
    }
}

private func sortIsIdempotent() async throws {
    try await withWorkspace { store in
        try await seedCluster(store)
        let organize = DunesCore.Organize(store: store)
        _ = try await organize.run()
        let first = try store.records(limit: 100).map { "\($0.title)=\($0.category ?? "-")" }.sorted()
        _ = try await organize.run()
        _ = try await organize.run()
        let third = try store.records(limit: 100).map { "\($0.title)=\($0.category ?? "-")" }.sorted()
        await expectEqual(first, third, "categories settle rather than drifting each run")
    }
}

private func backlogResumes() async throws {
    try await withWorkspace { store in
        // Files read with no model connected stay at `.rendered`. Connecting one later
        // has to pick them up — that's the whole "no key wall" promise.
        let folder = try fixture("lease.pdf").deletingLastPathComponent()
        _ = try await Ingest(store: store).addContents(of: folder)

        let pending = try store.recentDocuments(limit: 200).filter { $0.stage == .rendered }
        await expect(!pending.isEmpty, "documents wait at the rendered stage")

        let librarian = Librarian(store: store, provider: MockProvider())
        let summary = try await librarian.understandBacklog()
        await expect(summary.understood > 0, "the backlog is picked up when a model appears")

        let stillWaiting = try store.recentDocuments(limit: 200).filter { $0.stage == .rendered }
        await expect(stillWaiting.count < pending.count, "and the queue drains")
    }
}

// MARK: - Gate boundaries

private func roleNouns() async throws {
    let gate = EntityGate(documentText: """
        The tenant and the policyholder and the cardholder and the beneficiary
        all signed. So did Marguerite Vandermeer.
        """)
    for role in ["Tenant", "Policyholder", "Cardholder", "Beneficiary"] {
        if case .admit = gate.judge(name: role, kind: .person) {
            await expect(false, "\(role) should be refused as a role")
        } else {
            await expect(true, "\(role) is refused")
        }
    }
    // A real name of similar length must still get through, or the rule is too greedy.
    if case .admit = gate.judge(name: "Marguerite Vandermeer", kind: .person) {
        await expect(true, "an actual person is still admitted")
    } else {
        await expect(false, "a real name was wrongly refused")
    }
}

private func paperworkNouns() async throws {
    let gate = EntityGate(documentText: "Deposit 2,400.00. Balance 1,284.55. Premium paid. Harbourview Inn.")
    for word in ["Deposit", "Balance", "Premium"] {
        if case .admit = gate.judge(name: word, kind: .org) {
            await expect(false, "\(word) should be refused as paperwork vocabulary")
        } else {
            await expect(true, "\(word) is refused")
        }
    }
    if case .admit = gate.judge(name: "Harbourview Inn", kind: .org) {
        await expect(true, "a real business on the same page is admitted")
    } else {
        await expect(false, "a real business was wrongly refused")
    }
}

private func shortFormBoundary() async throws {
    // Three characters is enough when the full name has more words — an organization
    // abbreviated to "Eye" is still unmistakably that organization.
    await expect(Consolidate.sameThing("eye care of east bay", "eye") != nil,
                 "a three-letter short form merges")
    await expect(Consolidate.sameThing("harbourview inn", "harbourview") != nil,
                 "so does a long one")
    // But words that begin half the names in the world must not.
    await expect(Consolidate.sameThing("the chen clinic", "the") == nil,
                 "a leading article never merges")
    await expect(Consolidate.sameThing("san francisco housing", "san") == nil,
                 "nor a place-name prefix")
    await expect(Consolidate.sameThing("anna", "ann") == nil,
                 "and single words still never absorb each other")
}

/// Six records in two groups that share nothing across the divide.
private func seedCluster(_ store: Store) async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ij-rb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let ingest = Ingest(store: store)
    for (index, group) in [("Alcon Supply", "Finances"), ("Chen Clinic", "Health")].enumerated() {
        for copy in 0..<3 {
            let file = folder.appendingPathComponent("doc\(index)\(copy).md")
            try "# Note \(index)\(copy)\n\nAbout \(group.0) today.".write(to: file, atomically: true, encoding: .utf8)
            let result = try await ingest.add(fileAt: file)
            _ = try await Distill(store: store, provider: ScriptedProvider(json: """
            {"title":"Note \(index)\(copy)","category":"\(group.1)","summary":"s","kind":"note",
             "fields":[],"dates":[],
             "entities":[{"name":"\(group.0)","kind":"org","relation":"mentions"}]}
            """)).understand(documentID: try require(result.document.id, "id"))
        }
    }
}
