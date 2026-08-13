import Foundation
import DunesCore

func namingChecks() async {
    print("\nNaming · documents called what they are")
    await check("subject, party and date make a name", fullName)
    await check("an undated document doesn't get an invented date", undatedName)
    await check("the party isn't repeated when the subject already names it", partyNotRepeated)
    await check("a passing mention doesn't become the party", relationPriority)
    await check("an empty title falls back to what kind of thing it is", weakTitle)
    await check("a document the graph couldn't place isn't named after the bucket", holdingCategory)
    await check("nothing to add means no rename", nothingToAdd)
    await check("path characters never reach a filename", sanitizing)
    await check("a shouted title comes down, acronyms don't", shouting)
    await check("a very long name is cut at a word, keeping date and party", longName)
    await check("two documents with one name are numbered", collisions)
    await check("naming is idempotent", idempotent)
    await check("understanding a document renames it and keeps the original", endToEnd)
    await check("export writes copies under the new names", exporting)
}

// MARK: - The rule itself, checked without a database

private func record(title: String, kind: String? = nil, category: String? = nil,
                    on date: String? = nil) -> Record {
    Record(documentID: 1, kind: kind, title: title, category: category,
           happenedOn: date.flatMap { text in
               let formatter = DateFormatter()
               formatter.locale = Locale(identifier: "en_US_POSIX")
               formatter.timeZone = .current
               formatter.dateFormat = "yyyy-MM-dd"
               return formatter.date(from: text)
           })
}

private func fullName() async throws {
    // The shape a filing clerk would write: when, what, who.
    let proposed = Naming.propose(
        record: record(title: "Travel insurance certificate", on: "2026-06-15"),
        parties: [Naming.Party(name: "ACE", kind: .org, relation: "issued_by")],
        arrivedAs: "Kian Feiz - ES COE Fall 2026.pdf")
    await expectEqual(proposed, "2026-06-15 Travel insurance certificate — ACE.pdf",
                      "date, subject and issuer, in that order")
}

private func undatedName() async throws {
    // A résumé has no date of its own. Naming one "2026-01-01 …" would claim a day the
    // document never gave.
    let proposed = Naming.propose(
        record: record(title: "Resume"),
        parties: [Naming.Party(name: "Kian Feiz", kind: .person, relation: "party_to")],
        arrivedAs: "KianJFResume.pdf")
    await expectEqual(proposed, "Resume — Kian Feiz.pdf", "no date, no invented date")
}

private func partyNotRepeated() async throws {
    let proposed = Naming.propose(
        record: record(title: "Alcon Supply invoice"),
        parties: [Naming.Party(name: "Alcon Supply, Inc.", kind: .org, relation: "issued_by")],
        arrivedAs: "inv_0042.pdf")
    await expectEqual(proposed, "Alcon Supply invoice.pdf",
                      "the subject already names them, so the party is dropped")
}

private func relationPriority() async throws {
    // A document can mention a dozen names. Only the one it's *with* belongs in the name.
    let proposed = Naming.propose(
        record: record(title: "Lease", on: "2026-03-01"),
        parties: [
            Naming.Party(name: "City of San Jose", kind: .org, relation: "mentions"),
            Naming.Party(name: "Ridgeline Properties", kind: .org, relation: "party_to"),
        ],
        arrivedAs: "doc.pdf")
    await expectEqual(proposed, "2026-03-01 Lease — Ridgeline Properties.pdf",
                      "the counterparty wins over the mention")
}

private func weakTitle() async throws {
    // Extraction sometimes has nothing to say. "Untitled" is not a name.
    let proposed = Naming.propose(
        record: record(title: "Untitled", kind: "lease", on: "2026-03-01"),
        parties: [], arrivedAs: "scan_0001.pdf")
    await expectEqual(proposed, "2026-03-01 Lease.pdf", "it falls through to the kind, capitalized")

    let fromCategory = Naming.propose(
        record: record(title: "Document", category: "Policies"),
        parties: [Naming.Party(name: "ACE", kind: .org, relation: "issued_by")],
        arrivedAs: "scan_0002.pdf")
    await expectEqual(fromCategory, "Policy — ACE.pdf", "and then to the category, singular")
}

private func holdingCategory() async throws {
    // Found by running a real certificate through with a weak extraction: the graph
    // couldn't place it, so it sat in "Everything else" — and the file was named
    // "Everything else.pdf", stating a failure of ours as a fact about the document.
    let proposed = Naming.propose(
        record: record(title: "Untitled document", category: Organize.holdingCategory),
        parties: [], arrivedAs: "Kian Feiz - ES COE Fall 2026.pdf")
    await expect(proposed == nil, "it keeps the name it arrived with instead")

    // A real category still works as a fallback.
    let placed = Naming.propose(
        record: record(title: "Untitled document", category: "Health"),
        parties: [], arrivedAs: "scan.pdf")
    await expectEqual(placed, "Health.pdf", "a category the graph did settle on is usable")
}

private func nothingToAdd() async throws {
    // No subject, no date, no party. Renaming would only churn.
    let proposed = Naming.propose(record: record(title: "Untitled"), parties: [],
                                 arrivedAs: "scan_0001.pdf")
    await expect(proposed == nil, "the file keeps the name it arrived with")

    // And proposing the name it already has is the same as proposing nothing.
    let same = Naming.propose(record: record(title: "Quarterly report"), parties: [],
                              arrivedAs: "Quarterly report.pdf")
    await expect(same == nil, "no change is reported as no change")
}

private func sanitizing() async throws {
    // "/" is the path separator on disk, ":" the one the Finder shows. A title can
    // contain both, and writing either into a filename is how you get a stray folder.
    let proposed = try require(Naming.propose(
        record: record(title: "Invoice 4/2026: final"),
        parties: [], arrivedAs: "x.pdf"), "a name")
    await expect(!proposed.contains("/"), "no slash survives")
    await expect(!proposed.contains(":"), "no colon survives")
    await expectEqual(proposed, "Invoice 4-2026 - final.pdf", "and it still reads properly")

    // A leading dot would hide the file; trailing dots and spaces get trimmed by some
    // tools and kept by others, which is how two identical-looking names stop matching.
    await expectEqual(Naming.sanitize("  .hidden thing. "), "hidden thing",
                      "leading and trailing dots and spaces are trimmed")
    await expectEqual(Naming.sanitize("two\nlines\tand   spaces"), "two lines and spaces",
                      "newlines, tabs and runs of space collapse")
}

private func shouting() async throws {
    // Titles lifted from a heading arrive in capitals. A filename in capitals is
    // unpleasant to read — but "UC3M" and "EPS" are names, not shouting.
    await expectEqual(Naming.unshout("STEPS BEFORE ARRIVING UC3M EPS"),
                      "Steps before arriving UC3M EPS",
                      "long words come down, short ones stay")
    await expectEqual(Naming.unshout("Lease Agreement"), "Lease Agreement",
                      "an ordinary title is untouched")
    await expectEqual(Naming.unshout("ACME LLC"), "ACME LLC",
                      "two words are left alone — too short to be a sentence")
}

private func longName() async throws {
    let sprawling = "Certificate of insurance for international study abroad travel "
        + "covering medical evacuation repatriation and third party liability for the "
        + "academic year"
    let proposed = try require(Naming.propose(
        record: record(title: sprawling, on: "2026-06-15"),
        parties: [Naming.Party(name: "ACE", kind: .org, relation: "issued_by")],
        arrivedAs: "long.pdf"), "a name")

    await expect(proposed.count <= 110, "the name is a name, not a paragraph")
    await expect(proposed.hasPrefix("2026-06-15 "), "the date survives the cut")
    await expect(proposed.hasSuffix(" — ACE.pdf"), "and so does the party")
    // Cut at a word boundary: a name ending mid-syllable looks like corruption.
    let stem = (proposed as NSString).deletingPathExtension
    let subject = stem.replacingOccurrences(of: "2026-06-15 ", with: "")
        .replacingOccurrences(of: " — ACE", with: "")
    await expect(sprawling.hasPrefix(subject), "what's kept is a prefix of the title")
    await expect(sprawling.dropFirst(subject.count).first == " " || subject == sprawling,
                 "and it ends on a whole word")
}

private func collisions() async throws {
    // Two different files can honestly deserve the same name. Numbering them is honest;
    // showing one name twice isn't.
    let taken: Set<String> = ["2026-03-01 Invoice — Alcon.pdf"]
    await expectEqual(Naming.unique("2026-03-01 Invoice — Alcon.pdf", among: taken),
                      "2026-03-01 Invoice — Alcon (2).pdf", "the second one is numbered")
    await expectEqual(Naming.unique("2026-03-02 Invoice — Alcon.pdf", among: taken),
                      "2026-03-02 Invoice — Alcon.pdf", "a distinct name is left alone")
    // Case differences don't make a name distinct on a Mac's default filesystem.
    await expectEqual(Naming.unique("2026-03-01 invoice — alcon.pdf", among: taken),
                      "2026-03-01 invoice — alcon (2).pdf", "case-insensitively too")
}

private func idempotent() async throws {
    let sample = record(title: "Travel insurance certificate", on: "2026-06-15")
    let parties = [Naming.Party(name: "ACE", kind: .org, relation: "issued_by")]
    let once = Naming.propose(record: sample, parties: parties, arrivedAs: "a.pdf")
    let twice = Naming.propose(record: sample, parties: parties, arrivedAs: "a.pdf")
    await expectEqual(once, twice, "the same record always gives the same name")
    // Order of parties is an accident of the database, not a fact about the document.
    let reversed = Naming.propose(record: sample, parties: parties.reversed(), arrivedAs: "a.pdf")
    await expectEqual(once, reversed, "and party order doesn't change it")
}

// MARK: - Through the pipeline

private func endToEnd() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(result.document.id, "document id")
        await expect(result.document.displayName == nil, "a file just read has no derived name yet")

        _ = try await Distill(store: store, provider: MockProvider()).understand(documentID: documentID)
        let after = try require(try store.document(id: documentID), "the document")

        await expect(after.displayName != nil, "understanding it earns it a name")
        await expectEqual(after.name, "lease.pdf", "the name it arrived with is untouched")
        await expect(after.label != after.name, "and the library shows the new one")
        await expect(after.wasRenamed, "which the UI can tell")

        // The file on disk is the user's. A better name is a label, not a move.
        let vault = store.vault.url(for: after.vaultPath)
        await expect(FileManager.default.fileExists(atPath: vault.path),
                     "the vault copy stays exactly where the database says it is")
        await expectEqual(vault.lastPathComponent, "lease.pdf", "under its original filename")
    }
}

private func exporting() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        _ = try await Distill(store: store, provider: MockProvider())
            .understand(documentID: try require(result.document.id, "document id"))

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let written = try Namer(store: store).export(to: folder)
        await expectEqual(written.count, 1, "one document, one file out")
        let exported = try require(written.first, "the export")
        await expectEqual(exported.from, "lease.pdf", "reported from its arrival name")
        await expect(exported.to != "lease.pdf", "to its derived one")
        await expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(exported.to).path), "and the file is there")

        // Exporting twice adds rather than overwrites — the second copy is numbered.
        let again = try Namer(store: store).export(to: folder)
        await expect(again.first?.to != exported.to, "a second export doesn't clobber the first")
    }
}
