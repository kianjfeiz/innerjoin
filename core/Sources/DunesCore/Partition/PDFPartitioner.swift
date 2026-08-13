import Foundation
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers

/// Reads PDFs page by page.
///
/// Per page: if there's a usable text layer, take it (free, exact, no OCR errors).
/// If there isn't, rasterize that page and hand it to Vision. Deciding per page
/// rather than per file means a scanned page inside a digital document still gets read.
public struct PDFPartitioner: Partitioner {
    /// Below this many characters, a page is treated as scanned.
    let textLayerThreshold = 40
    /// Rasterization resolution for OCR. 200 dpi is the usual accuracy/speed sweet spot.
    let ocrDPI: CGFloat = 200

    public init() {}

    public func handles(_ type: UTType) -> Bool { type.conforms(to: .pdf) }

    public func partition(fileAt url: URL) async throws -> PartitionOutput {
        guard let pdf = PDFDocument(url: url) else {
            throw PartitionError.unreadable("This PDF could not be opened.")
        }
        if pdf.isEncrypted && pdf.isLocked { throw PartitionError.passwordProtected }
        guard pdf.pageCount > 0 else { throw PartitionError.empty }

        var elements: [DraftElement] = []
        var warnings: [String] = []
        var ocrPages = 0

        // Body size is measured once across the whole document. Per page it's unstable:
        // a page that's mostly headings would call heading size "normal".
        let bodySize = documentBodySize(of: pdf)

        var tablePages = 0

        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let pageNumber = index + 1
            let text = page.string ?? ""
            let hasUsableTextLayer = text.trimmed.count >= textLayerThreshold
                && !Self.looksLikeGarbage(text)

            if hasUsableTextLayer {
                var pageElements = textLayerElements(of: page, pageNumber: pageNumber,
                                                     bodySize: bodySize)

                // Second pass, only where it earns its cost. PDFKit gives exact
                // characters but knows nothing about tables; Vision reconstructs table
                // structure but can misread characters. On a page that looks tabular,
                // take structure from Vision and text from the text layer everywhere else.
                if looksTabular(page), let image = render(page) {
                    let recognized = try await VisionReader.read(image: image, page: pageNumber)
                    let tables = recognized.filter { $0.kind == .table }
                    let tableBoxes = tables.compactMap(\.box)
                    if !tableBoxes.isEmpty {
                        tablePages += 1
                        pageElements = pageElements.filter { element in
                            guard let box = element.box else { return true }
                            return !tableBoxes.contains { $0.contains(box) }
                        }
                        pageElements.append(contentsOf: tables)
                        pageElements.sort { ($0.box?.y ?? 0) < ($1.box?.y ?? 0) }
                    }
                }
                elements.append(contentsOf: pageElements)

            } else if let image = render(page) {
                ocrPages += 1
                elements.append(contentsOf: try await VisionReader.read(image: image, page: pageNumber))
            } else {
                warnings.append("Page \(pageNumber) could not be read.")
            }
        }

        if tablePages > 0 {
            warnings.append("Recovered tables on \(tablePages) page\(tablePages == 1 ? "" : "s").")
        }

        if ocrPages > 0 {
            warnings.append("\(ocrPages) of \(pdf.pageCount) page\(pdf.pageCount == 1 ? "" : "s") needed text recognition.")
        }
        guard !elements.isEmpty else {
            throw PartitionError.unreadable("No readable text was found in this PDF.")
        }
        return PartitionOutput(elements: elements, pageCount: pdf.pageCount, warnings: warnings)
    }

    // MARK: - Text layer

    /// The document's body text size: the size that the most *characters* are set in.
    ///
    /// Counting characters rather than lines is what makes this reliable — headings are
    /// short, so even a page with many of them is still mostly body text by volume.
    private func documentBodySize(of pdf: PDFDocument) -> CGFloat {
        var charactersBySize: [CGFloat: Int] = [:]
        for index in 0..<pdf.pageCount {
            guard let attributed = pdf.page(at: index)?.attributedString, attributed.length > 0
            else { continue }
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                // Round to the nearest half point so 11.0 and 11.04 count as the same size.
                let size = (font.pointSize * 2).rounded() / 2
                charactersBySize[size, default: 0] += range.length
            }
        }
        return charactersBySize.max { $0.value < $1.value }?.key ?? 0
    }

    /// Groups a page's text into paragraphs and headings, with coordinates taken
    /// from the PDF itself — no OCR, so no recognition errors.
    private func textLayerElements(of page: PDFPage, pageNumber: Int, bodySize: CGFloat) -> [DraftElement] {
        guard let attributed = page.attributedString, attributed.length > 0 else { return [] }
        let full = attributed.string as NSString
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return [] }

        // Split into lines. Blank lines are kept as markers — they're the strongest
        // signal of a paragraph break, and dropping them merges unrelated text.
        struct Line {
            var range: NSRange; var text: String
            var size: CGFloat; var isBold: Bool; var isBlank: Bool
            /// Where the line starts on the page, normalized. Carried because a change
            /// of left edge is the clearest sign of a new column or a new paragraph.
            var x: Double; var y: Double
        }
        var lines: [Line] = []
        full.enumerateSubstrings(in: NSRange(location: 0, length: full.length),
                                 options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let text = full.substring(with: range)
            if text.trimmed.isEmpty {
                lines.append(Line(range: range, text: "", size: 0, isBold: false,
                                  isBlank: true, x: 0, y: 0))
                return
            }
            let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let start = page.characterBounds(at: range.location)
            lines.append(Line(
                range: range, text: text.trimmed,
                size: font?.pointSize ?? 0,
                isBold: font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
                isBlank: false,
                x: Double((start.minX - bounds.minX) / bounds.width),
                y: Double((bounds.maxY - start.maxY) / bounds.height)
            ))
        }
        guard lines.contains(where: { !$0.isBlank }) else { return [] }

        // Merge consecutive lines into a paragraph. A blank line, a size or weight
        // change, a bullet, or a jump in position starts a new block.
        var blocks: [[Line]] = []
        for line in lines {
            guard !line.isBlank else { blocks.append([]); continue }
            if var last = blocks.last, let previous = last.last,
               !Self.isBullet(line.text), !Self.isBullet(previous.text),
               abs(previous.size - line.size) < 0.5, previous.isBold == line.isBold,
               // A different left edge means a different column, or at least a
               // different paragraph — either way, not a continuation of this one.
               abs(previous.x - line.x) < 0.06,
               // Text that jumps back up the page has started a new column.
               line.y >= previous.y - 0.01 {
                last.append(line)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append([line])
            }
        }

        let drafted = blocks.compactMap { block -> DraftElement? in
            guard let first = block.first, let last = block.last else { return nil }
            let text = Self.join(block.map(\.text))
            guard !text.isEmpty else { return nil }

            let span = NSRange(location: first.range.location,
                               length: NSMaxRange(last.range) - first.range.location)
            let box = boundingBox(of: span, on: page, in: bounds)

            let (kind, depth) = Self.classify(text, size: first.size,
                                              bodySize: bodySize, isBold: first.isBold)
            return DraftElement(kind, text, page: pageNumber, box: box, depth: depth)
        }
        return Self.inReadingOrder(drafted)
    }

    /// Unions the character bounds across a range and converts PDF's bottom-left
    /// point space into our top-left normalized space.
    private func boundingBox(of range: NSRange, on page: PDFPage, in bounds: CGRect) -> BBox? {
        var union: CGRect?
        // Sampling keeps this cheap on dense pages; the union is the same to within a hair.
        let step = max(1, range.length / 96)
        for offset in stride(from: 0, to: range.length, by: step) {
            let rect = page.characterBounds(at: range.location + offset)
            guard rect.width > 0 || rect.height > 0 else { continue }
            union = union.map { $0.union(rect) } ?? rect
        }
        guard let box = union else { return nil }
        return BBox(
            x: Double((box.minX - bounds.minX) / bounds.width),
            y: Double((bounds.maxY - box.maxY) / bounds.height),
            width: Double(box.width / bounds.width),
            height: Double(box.height / bounds.height)
        )
    }

    /// Puts a page's blocks into the order a person would read them.
    ///
    /// PDF text comes out in drawing order, which for a two-column page can interleave
    /// the columns line by line — the resulting prose is scrambled, and every sentence
    /// spanning a column break is nonsense. Finding the gutter and reading one column
    /// fully before the next is what fixes it.
    static func inReadingOrder(_ elements: [DraftElement]) -> [DraftElement] {
        let boxed = elements.compactMap { element -> (DraftElement, BBox)? in
            element.box.map { (element, $0) }
        }
        // Without geometry there's nothing to reason about; keep what we were given.
        guard boxed.count == elements.count, boxed.count > 3 else { return elements }

        guard let gutter = verticalGutter(in: boxed.map(\.1)) else {
            // Single column: plain top-to-bottom, left-to-right within a line.
            return boxed.sorted { a, b in
                abs(a.1.y - b.1.y) < 0.012 ? a.1.x < b.1.x : a.1.y < b.1.y
            }.map(\.0)
        }

        // Full-width blocks — a banner headline, a footer — belong to neither column
        // and must stay where they are relative to both.
        func column(_ box: BBox) -> Int {
            if box.x < gutter && box.x + box.width > gutter { return 0 }   // spans the gutter
            return box.x + box.width <= gutter ? 1 : 2
        }
        let spanning = boxed.filter { column($0.1) == 0 }
        let left = boxed.filter { column($0.1) == 1 }
        let right = boxed.filter { column($0.1) == 2 }

        // A page is only really two-column if both sides carry real content.
        guard left.count >= 2, right.count >= 2 else {
            return boxed.sorted { a, b in
                abs(a.1.y - b.1.y) < 0.012 ? a.1.x < b.1.x : a.1.y < b.1.y
            }.map(\.0)
        }

        // A full-width block above both columns is a heading; below them, a footer.
        let columnsStart = left.map(\.1.y).min() ?? 1
        let header = spanning.filter { $0.1.y < columnsStart }
        let footer = spanning.filter { $0.1.y >= columnsStart }
        func byHeight(_ items: [(DraftElement, BBox)]) -> [DraftElement] {
            items.sorted { $0.1.y < $1.1.y }.map(\.0)
        }
        return byHeight(header) + byHeight(left) + byHeight(right) + byHeight(footer)
    }

    /// Finds the x position of a vertical channel that no block crosses.
    ///
    /// Only the middle of the page is considered — margins are empty by definition, and
    /// treating a wide margin as a gutter would split a perfectly ordinary page in two.
    static func verticalGutter(in boxes: [BBox]) -> Double? {
        let steps = 100
        var occupied = [Bool](repeating: false, count: steps)
        for box in boxes {
            let from = max(0, Int(box.x * Double(steps)))
            let to = min(steps - 1, Int((box.x + box.width) * Double(steps)))
            guard from <= to else { continue }
            for index in from...to { occupied[index] = true }
        }

        // Look only between 25% and 75% of the width.
        var best: (position: Double, width: Int)?
        var runStart: Int?
        for index in Int(0.25 * Double(steps))...Int(0.75 * Double(steps)) {
            if occupied[index] {
                if let start = runStart {
                    let width = index - start
                    if width > (best?.width ?? 0) {
                        best = (Double(start + index) / 2.0 / Double(steps), width)
                    }
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = index
            }
        }
        if let start = runStart {
            let width = Int(0.75 * Double(steps)) - start
            if width > (best?.width ?? 0) {
                best = (Double(start) / Double(steps) + Double(width) / 2 / Double(steps), width)
            }
        }
        // A gutter narrower than 3% of the page is just word spacing.
        guard let best, best.width >= 3 else { return nil }
        return best.position
    }

    /// Guesses whether a page holds a table, from geometry alone.
    ///
    /// Table rows leave wide horizontal gaps at the same x positions line after line.
    /// Prose doesn't. Finding a gap column shared by several lines is a cheap, reliable
    /// signal, and it costs nothing on the pages that don't have one.
    private func looksTabular(_ page: PDFPage) -> Bool {
        guard let text = page.string as NSString?, text.length > 0 else { return false }
        let columnBucket: CGFloat = 12   // points; groups gaps that line up
        var linesPerColumn: [Int: Int] = [:]

        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 8 else { return }
            let line = text.substring(with: range) as NSString
            let limit = min(range.length, 300)

            // PDFKit doesn't leave a gap between columns — it *stretches the last glyph
            // of a cell* so its bounds run all the way to the next column. In a table
            // header, the "m" of "Item" comes back 204pt wide. So a column boundary is
            // an abnormally wide character, and the boundary sits at its right edge.
            var bounds: [CGRect] = []
            for offset in 0..<limit {
                let rect = page.characterBounds(at: range.location + offset)
                if rect.width > 0 { bounds.append(rect) }
            }
            guard bounds.count > 4 else { return }
            // Median is unaffected by the handful of stretched glyphs we're looking for.
            let typical = bounds.map(\.width).sorted()[bounds.count / 2]
            guard typical > 0 else { return }

            var previousMaxX: CGFloat?
            for rect in bounds {
                if rect.width > typical * 3 {
                    linesPerColumn[Int(rect.maxX / columnBucket), default: 0] += 1
                } else if let previous = previousMaxX, rect.minX - previous > typical * 3 {
                    linesPerColumn[Int(rect.minX / columnBucket), default: 0] += 1
                }
                previousMaxX = rect.maxX
            }
            _ = line
        }
        // Three rows sharing a column boundary is a table, not a coincidence.
        return linesPerColumn.values.contains { $0 >= 3 }
    }

    // MARK: - Rasterize

    private func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        // A page can carry a rotation — a scan fed in sideways is the usual cause.
        // `draw` honours it, so the canvas has to be sized to the page as *displayed*,
        // not as stored. Sized wrongly, the content lands outside the bitmap and the
        // page comes back blank.
        let quarterTurn = Self.isQuarterTurned(page)
        let displayed = quarterTurn
            ? CGSize(width: bounds.height, height: bounds.width)
            : CGSize(width: bounds.width, height: bounds.height)

        let scale = ocrDPI / 72.0
        let width = Int(displayed.width * scale), height = Int(displayed.height * scale)
        guard width > 0, height > 0, width * height < 80_000_000 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)

        // `draw` applies the page's /Rotate itself — verified against PDFKit's own
        // thumbnail, which produces an identical image. So the only thing needed here
        // is a canvas shaped like the page *as displayed*; rotating again would put
        // the content outside the bitmap and yield a blank page.
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    static func rotation(of page: PDFPage) -> Int {
        ((page.rotation % 360) + 360) % 360
    }

    static func isQuarterTurned(_ page: PDFPage) -> Bool {
        let turn = rotation(of: page)
        return turn == 90 || turn == 270
    }

    /// Shared with the rich-text reader so both agree on what a heading looks like.
    ///
    /// Size wins over numbering: "14. Early Termination" set larger than the body is a
    /// heading, not a list item. Contracts and leases number their sections, and getting
    /// this backwards flattens a document's whole structure.
    ///
    /// Weight matters as much as size. Plenty of contracts set headings in bold at body
    /// size — without checking weight, every one of those disappears into the prose.
    public static func classify(_ text: String, size: CGFloat, bodySize: CGFloat, isBold: Bool = false)
        -> (kind: ElementKind, depth: Int)
    {
        if bodySize > 0 {
            if size >= bodySize * 1.45 { return (.title, 0) }
            if size >= bodySize * 1.15 { return (.title, 1) }
        }
        // Bold at body size is a heading only if it's short and isn't a sentence —
        // otherwise emphasized sentences inside a paragraph would become headings.
        if isBold, text.count <= 80, !text.hasSuffix("."), !isBullet(text) {
            return (.title, 2)
        }
        if isBullet(text) { return (.listItem, 0) }
        return (.text, 0)
    }

    /// Rejoins words split across a line break: "compre-\nhensive" → "comprehensive".
    /// Left alone, the word is unsearchable and reads as two tokens to a model.
    public static func join(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            guard !out.isEmpty else { out = line; continue }
            if out.hasSuffix("-"), let next = line.first, next.isLowercase {
                out.removeLast()
                out += line
            } else {
                out += " " + line
            }
        }
        return out.trimmed
    }

    /// True when extracted text is mostly junk — broken font encodings produce
    /// confident-looking garbage, which is worse than no text layer at all.
    public static func looksLikeGarbage(_ text: String) -> Bool {
        let sample = text.prefix(2000)
        guard sample.count >= 40 else { return false }
        let readable = sample.filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0.isPunctuation }
        return Double(readable.count) / Double(sample.count) < 0.8
    }

    static func isBullet(_ text: String) -> Bool {
        text.starts(with: "•") || text.starts(with: "- ") || text.starts(with: "* ")
            || text.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

}
