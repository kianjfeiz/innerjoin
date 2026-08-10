import Foundation
import InnerjoinCore

func formatChecks() async {
    print("\nStage 1 · more formats")
    await check("spreadsheets resolve shared strings and keep column gaps", spreadsheets)
    await check("slides come out in numeric order, not lexical", slides)
    await check("email decodes encoded subjects and quoted-printable bodies", email)
    await check("email drops the quoted thread and names attachments", emailThreading)
    await check("multi-column pages read down one column then the next", columnOrder)
    await check("zip reading survives a truncated archive", corruptArchive)
}

private func spreadsheets() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("ledger.xlsx"))
        let markdown = try require(result.document.markdown, "markdown")

        // Cell text lives in a shared table referenced by index — without resolving it
        // every string cell would come out as a bare number.
        await expect(markdown.contains("Alcon Supply"), "shared strings are resolved")
        await expect(markdown.contains("| Date | Vendor | Amount | Category |"), "the header row survives")
        // Spreadsheets omit empty cells entirely; the columns must still line up.
        await expect(markdown.contains("| 2026-07-28 |   | 3200 | rent |"),
                     "a missing cell keeps its column rather than shifting the row")
    }
}

private func slides() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("review.pptx"))
        let markdown = try require(result.document.markdown, "markdown")

        // The fixture stores slides as 10, 2, 1 inside the archive. Sorting by name
        // would put slide10 first and silently reverse the deck.
        let first = try require(markdown.range(of: "Quarterly review"), "slide 1")
        let second = try require(markdown.range(of: "Spend by vendor"), "slide 2")
        let last = try require(markdown.range(of: "Next steps"), "slide 10")
        await expect(first.lowerBound < second.lowerBound && second.lowerBound < last.lowerBound,
                     "slides are ordered 1, 2, 10 — numerically")
        await expectEqual(result.document.pageCount, 3, "each slide counts as a page")
    }
}

private func email() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("amendment.eml"))
        let markdown = try require(result.document.markdown, "markdown")

        // The subject arrives base64-encoded inside =?utf-8?B?...?=
        await expect(markdown.contains("Re: lease amendment"), "the encoded subject is decoded")
        await expect(markdown.contains("m.osei@example.com"), "the sender is kept as a fact")
        // "redu=\nced" and "=27" are quoted-printable; left raw the text is unreadable.
        await expect(markdown.contains("reduced to one month's rent"),
                     "quoted-printable body is decoded, soft breaks and all")
        await expect(!markdown.contains("=27"), "no escape sequences leak through")
    }
}

private func emailThreading() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("amendment.eml"))
        let markdown = try require(result.document.markdown, "markdown")

        // Quoted history repeats across every message in a thread. Keeping it would
        // duplicate the same text through the library and skew every count.
        await expect(!markdown.contains("Can we revisit the two month penalty"),
                     "the quoted reply is dropped")
        // An attachment is its own document; naming it is honest, parsing it here isn't.
        await expect(result.document.problem?.contains("amendment.pdf") == true,
                     "attachments are named rather than silently ignored")
    }
}

private func columnOrder() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("two_column.pdf"))
        let markdown = try require(result.document.markdown, "markdown")

        // The fixture draws the columns interleaved line by line. Read in draw order
        // the prose is scrambled; read by column it makes sense.
        let leftEnd = try require(markdown.range(of: "the lowest in four quarters"), "end of the left column")
        let rightStart = try require(markdown.range(of: "Costs grew"), "start of the right column")
        await expect(leftEnd.lowerBound < rightStart.lowerBound,
                     "the left column is read out fully before the right one begins")

        let heading = try require(markdown.range(of: "QUARTERLY REPORT"), "the heading")
        await expect(heading.lowerBound < leftEnd.lowerBound, "a full-width heading stays on top")
        await expect(markdown.contains("Prepared by finance"), "and a full-width footer stays at the bottom")
    }
}

private func corruptArchive() async throws {
    try await withWorkspace { store in
        // Half an xlsx. It must fail as a readable problem, not a crash.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = try Data(contentsOf: try fixture("ledger.xlsx"))
        let truncated = folder.appendingPathComponent("broken.xlsx")
        try source.prefix(source.count / 2).write(to: truncated)

        let result = try? await Ingest(store: store).add(fileAt: truncated)
        if let result {
            await expectEqual(result.document.status, .failed, "a broken archive fails cleanly")
            await expect(result.document.problem?.isEmpty == false, "with a reason a person can read")
        } else {
            await expect(true, "a broken archive is refused")
        }
    }
}
