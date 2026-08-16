import Foundation
import DunesCore

@main
struct Checks {
    static func main() async throws {
        print("dunes preprocessor checks\n")

        print("Stage 0 · intake")
        await check("adding a file creates exactly one document", addingCreatesOneDocument)
        await check("the same file added twice is a no-op", duplicateIsNoOp)
        await check("the original is copied into the vault, untouched", vaultCopiesOriginal)

        print("\nStage 1 · partition")
        await check("pdf headings are told apart from body text", headingsVsBody)
        await check("pdf elements carry pages and coordinates", pagesAndCoordinates)
        await check("scanned pages fall back to text recognition", scannedFallback)
        await check("images are read, including table structure", imageTables)
        await check("delimited files keep quoted fields intact", quotedCSVFields)
        await check("markdown structure is preserved", markdownStructure)

        print("\nStage 1 · hard cases")
        await check("bold headings at body size are still headings", boldHeadings)
        await check("words split across line breaks are rejoined", hyphenation)
        await check("tables in text-layer pdfs are recovered", textLayerTables)
        await check("garbled text layers are recognized as junk", garbageDetection)

        await check("audio is transcribed with timestamps", needs: "speech", audioTranscription)

        await formatChecks()

        print("\nStage 2 · rendition")
        await check("rendition formats structure and anchors facts", renditionFormatting)
        await check("every anchor resolves to a real element", anchorsResolve)

        print("\nFailure handling")
        await check("an empty file is rejected without creating an entry", emptyFileRejected)
        await check("one bad file does not stop a folder", folderKeepsGoing)

        print("\nSearch")
        await check("full-text search works with no model connected", searchWithoutModel)

        await distillChecks()
        await consolidateChecks()
        await entityIdentityChecks()
        await staleLinkChecks()
        await organizeChecks()
        await shelfNameChecks()
        await categoryEvidenceChecks()
        await robustnessChecks()
        await learningChecks()
        await namingChecks()
        await providerChecks()
        await anchorFormatChecks()
        await askChecks()
        await voiceChecks()
        await markupChecks()
        await mcpChecks()
        await mailChecks()
        await peopleChecks()
        await nicknameDataChecks()
        await scrutinyChecks()
        await typoChecks()
        await writtenFormChecks()
        await discriminatorChecks()

        print("\nAgenda")
        await agendaChecks()

        print("\nGeometry")
        await check("bounding boxes convert from bottom-left origin", geometryConversion)

        let passed = await Report.shared.passed
        let skipped = await Report.shared.skipped
        let failures = await Report.shared.failures
        print("\n\(passed) checks passed, \(failures.count) failed"
            + (skipped > 0 ? ", \(skipped) skipped for want of a capability" : ""))
        for failure in failures { print("  ✗ \(failure)") }
        if !failures.isEmpty { exit(1) }
    }
}

// MARK: - Support

/// A throwaway workspace per check, removed afterwards.
func withWorkspace<T>(_ body: (Store) async throws -> T) async throws -> T {
    try await withWorkspace { store, _ in try await body(store) }
}

/// The same, for anything that writes files beside the database — mail, MCP pulls —
/// and so needs to know where the workspace actually is.
func withWorkspace<T>(_ body: (Store, URL) async throws -> T) async throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ij-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(try Store(root: root), root)
}

func fixture(_ name: String) throws -> URL {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
        throw CheckError("fixture \(name) is missing")
    }
    return url
}

private var fixturesFolder: URL { get throws { try fixture("lease.pdf").deletingLastPathComponent() } }

// MARK: - Stage 0

private func addingCreatesOneDocument() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        await expect(!result.wasAlreadyPresent, "a new file is not reported as already present")
        await expectEqual(result.document.name, "lease.pdf", "the document keeps its filename")
        await expectEqual(result.document.pageCount, 2, "page count is recorded")
        await expectEqual(result.document.status, .ok, "a clean read reports ok")
        await expectEqual(try store.counts().documents, 1, "one file makes one entry")
    }
}

private func duplicateIsNoOp() async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        let first = try await ingest.add(fileAt: try fixture("lease.pdf"))
        let second = try await ingest.add(fileAt: try fixture("lease.pdf"))

        await expect(second.wasAlreadyPresent, "the second add is recognized as a duplicate")
        await expectEqual(first.document.id, second.document.id, "it returns the same document")
        await expectEqual(try store.counts().documents, 1, "no duplicate row")
        await expectEqual(try store.counts().elements, first.elementCount, "no duplicate elements")
    }
}

private func vaultCopiesOriginal() async throws {
    try await withWorkspace { store in
        let source = try fixture("notes.md")
        let result = try await Ingest(store: store).add(fileAt: source)
        let stored = store.vault.url(for: result.document.vaultPath)

        await expect(FileManager.default.fileExists(atPath: stored.path), "the vault holds a copy")
        await expect(try Data(contentsOf: stored) == (try Data(contentsOf: source)),
                     "the copy is byte-identical")
        await expect(FileManager.default.fileExists(atPath: source.path),
                     "the user's own file is left alone")
    }
}

// MARK: - Stage 1

private func headingsVsBody() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let elements = try store.elements(of: try require(result.document.id, "document id"))
        let titles = elements.filter { $0.kind == .title }.map(\.text)

        await expect(titles.contains("RESIDENTIAL LEASE AGREEMENT"), "the document title is a heading")
        // Contracts number their sections; size has to win over numbering or the
        // whole structure collapses into a bullet list.
        await expect(titles.contains("14. Early Termination"), "a numbered section is a heading")
        await expect(titles.contains("3. Rent"), "numbered sections on page 1 too")
        await expect(!elements.contains { $0.kind == .listItem && $0.text.hasPrefix("3. Rent") },
                     "a numbered heading is not filed as a list item")
    }
}

private func pagesAndCoordinates() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let elements = try store.elements(of: try require(result.document.id, "document id"))

        await expect(elements.allSatisfy { $0.page != nil }, "every pdf element knows its page")
        await expect(elements.contains { $0.page == 2 }, "page 2 was read")

        let title = try require(elements.first { $0.kind == .title }, "a title element")
        let box = try require(title.box, "the title's box")
        await expect(box.x >= 0 && box.x <= 1 && box.y >= 0 && box.y <= 1,
                     "coordinates are normalized to 0...1")
        await expect(box.y < 0.25, "top-left origin: the title sits near the top of the page")
        await expect(box.width > 0 && box.height > 0, "the box has real size")
    }
}

private func scannedFallback() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("scanned_receipt.pdf"))
        await expect(result.elementCount > 0, "a pdf with no text layer still yields content")
        await expectEqual(result.document.status, .partial, "and says the read was imperfect")
        await expect(result.document.problem?.contains("text recognition") == true,
                     "the reason is in plain language")

        let markdown = try require(result.document.markdown, "markdown")
        await expect(markdown.contains("ALCON"), "the recognized text made it through")
    }
}

private func imageTables() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("receipt.png"))
        let elements = try store.elements(of: try require(result.document.id, "document id"))

        let table = try require(elements.first { $0.kind == .table }, "a table element")
        await expect(table.text.contains("Surgical gloves"), "table cells are captured")
        await expect(table.text.contains("$216.00"), "amounts survive recognition")
        await expect(table.text.contains("|"), "tables are stored as markdown")
        await expectEqual(result.document.pageCount, 1, "an image counts as one page")
    }
}

private func quotedCSVFields() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("transactions.csv"))
        let markdown = try require(result.document.markdown, "markdown")
        // "PG&E, Inc." contains the delimiter — it must stay one field.
        await expect(markdown.contains("| PG&E, Inc. |"), "quoted fields containing commas survive")
        await expect(markdown.contains("| Figma | 252.00 | subscription |"), "rows line up")
    }
}

private func markdownStructure() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("notes.md"))
        let elements = try store.elements(of: try require(result.document.id, "document id"))
        await expect(elements.contains { $0.kind == .title && $0.text == "Apartment notes" },
                     "markdown headings become titles")
        await expect(elements.contains { $0.kind == .listItem }, "bullets become list items")
    }
}

// MARK: - Stage 1 · hard cases
//
// Each of these was a real failure caught by running adversarial documents through
// the reader. They're kept as checks so the fixes can't quietly regress.

private func boldHeadings() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("bold_headings.pdf"))
        let elements = try store.elements(of: try require(result.document.id, "document id"))
        let titles = elements.filter { $0.kind == .title }.map(\.text)

        // Contracts routinely set headings bold at body size. Judging on size alone
        // dissolved these into the surrounding prose.
        await expect(titles.contains("Termination"), "a bold heading at body size is a heading")
        await expect(titles.contains("Governing Law"), "and so is the next one")
        await expect(elements.count >= 4, "headings and bodies stay separate blocks")
    }
}

private func hyphenation() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("hyphenation.pdf"))
        let markdown = try require(result.document.markdown, "markdown")
        // Left broken, "compre- hensive" is unsearchable and reads as two tokens.
        await expect(markdown.contains("comprehensive"), "a hyphenated word is rejoined")
        await expect(markdown.contains("insurance"), "and the next one")
        await expect(!markdown.contains("- hensive"), "no orphaned fragments remain")
    }
}

private func textLayerTables() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("text_table.pdf"))
        let elements = try store.elements(of: try require(result.document.id, "document id"))

        // PDFKit reads characters but knows nothing about tables, so a tabular page
        // gets a second pass through Vision purely for its structure.
        let table = try require(elements.first { $0.kind == .table }, "a recovered table")
        await expect(table.text.contains("| Surgical gloves |"), "rows come back as rows")
        await expect(table.text.contains("$216.00"), "amounts land in their cells")
        await expect(result.document.problem?.contains("Recovered tables") == true,
                     "the second pass is reported honestly")
    }
}

private func garbageDetection() async throws {
    // A broken font encoding yields confident-looking nonsense. Better to treat it as
    // no text layer and let recognition try than to store junk.
    await expect(PDFPartitioner.looksLikeGarbage(String(repeating: "\u{FFFD}\u{0001}", count: 40)),
                 "control characters and replacement marks read as junk")
    await expect(!PDFPartitioner.looksLikeGarbage(
        "Tenant shall pay $3,200.00 per month, due on the first day of each month."),
                 "ordinary prose is not junk")
}

private func audioTranscription() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("memo.m4a"))
        let markdown = try require(result.document.markdown, "a transcript")
        // Timestamps stand in for page numbers: audio has no geometry to cite.
        await expect(markdown.contains("[0:00]"), "utterances are stamped with their time")
        await expect(markdown.lowercased().contains("lease"), "the speech was recognized")
        await expect(result.elementCount > 1, "the transcript is split into citable pieces")
        await expect(result.document.problem?.contains("Transcribed") == true,
                     "the duration is reported")
    }
}

// MARK: - Stage 2

private func renditionFormatting() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let markdown = try require(result.document.markdown, "markdown")

        await expect(markdown.contains("# RESIDENTIAL LEASE AGREEMENT"), "titles render as headings")
        await expect(markdown.contains("<!-- page 2 -->"), "page markers let a model cite the right page")

        let anchoredAmount = markdown.range(of: #"\$3,200\.00[^\n]*\[e\d+\]"#, options: .regularExpression)
        await expect(anchoredAmount != nil, "a paragraph with an amount gets an anchor")
        await expect(!markdown.contains("(Tenant). [e"), "ordinary prose does not")
    }
}

private func anchorsResolve() async throws {
    try await withWorkspace { store in
        let result = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let markdown = try require(result.document.markdown, "markdown")
        let tags = Set(try store.elements(of: try require(result.document.id, "document id")).map(\.tag))

        let pattern = try NSRegularExpression(pattern: #"\[(e\d+)\]"#)
        let matches = pattern.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        await expect(!matches.isEmpty, "the rendition contains anchors")

        // The whole citation chain depends on this: an anchor that points nowhere
        // is a citation that can't be clicked.
        var dangling: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: markdown) else { continue }
            let tag = String(markdown[range])
            if !tags.contains(tag) { dangling.append(tag) }
        }
        await expect(dangling.isEmpty, "every anchor points at a real element; dangling: \(dangling)")
    }
}

// MARK: - Failures

private func emptyFileRejected() async throws {
    try await withWorkspace { store in
        var threw = false
        do { _ = try await Ingest(store: store).add(fileAt: try fixture("empty.txt")) }
        catch { threw = true }
        await expect(threw, "an empty file is refused")
        await expectEqual(try store.counts().documents, 0, "and leaves no clutter behind")
    }
}

private func folderKeepsGoing() async throws {
    try await withWorkspace { store in
        let results = try await Ingest(store: store).addContents(of: try fixturesFolder)
        await expect(results.count >= 5, "every readable file in the folder landed")
        await expect(results.allSatisfy { $0.document.id != nil }, "each one got a row")
    }
}

// MARK: - Search

private func searchWithoutModel() async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        _ = try await ingest.add(fileAt: try fixture("lease.pdf"))
        _ = try await ingest.add(fileAt: try fixture("notes.md"))

        let fillmore = try store.search("Fillmore")
        await expect(fillmore.contains { $0.name == "lease.pdf" }, "a word in the lease is found")

        let landlord = try store.search("Osei")
        await expectEqual(landlord.count, 2, "both files mentioning the landlord are found")

        await expect(try store.search("aardvark").isEmpty, "a word in nothing finds nothing")
    }
}

// MARK: - Geometry

private func geometryConversion() async throws {
    // Vision reports bottom-left origin, ours is top-left. Getting this backwards
    // would silently put every highlight on the wrong part of the page.
    let converted = BBox.fromBottomLeft(x: 0.1, y: 0.9, width: 0.2, height: 0.05)
    await expect(abs(converted.y - 0.05) < 0.0001, "a box at the top converts to a low y")
    await expectEqual(converted.x, 0.1, "x is unchanged")
    await expectEqual(converted.height, 0.05, "height is unchanged")
}
