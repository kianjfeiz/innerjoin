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

        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let pageNumber = index + 1
            let text = page.string ?? ""

            if text.trimmed.count >= textLayerThreshold {
                elements.append(contentsOf: textLayerElements(of: page, pageNumber: pageNumber,
                                                              bodySize: bodySize))
            } else if let image = render(page) {
                ocrPages += 1
                elements.append(contentsOf: try await VisionReader.read(image: image, page: pageNumber))
            } else {
                warnings.append("Page \(pageNumber) could not be read.")
            }
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

    /// Groups a page's text into paragraphs and headings, with coordinates taken
    /// from the PDF itself — no OCR, so no recognition errors.
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

    private func textLayerElements(of page: PDFPage, pageNumber: Int, bodySize: CGFloat) -> [DraftElement] {
        guard let attributed = page.attributedString, attributed.length > 0 else { return [] }
        let full = attributed.string as NSString
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return [] }

        // Split into lines. Blank lines are kept as markers — they're the strongest
        // signal of a paragraph break, and dropping them merges unrelated text.
        struct Line { var range: NSRange; var text: String; var size: CGFloat; var isBlank: Bool }
        var lines: [Line] = []
        full.enumerateSubstrings(in: NSRange(location: 0, length: full.length),
                                 options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let text = full.substring(with: range).trimmed
            let size = (attributed.attribute(.font, at: range.location, effectiveRange: nil)
                        as? NSFont)?.pointSize ?? 0
            lines.append(Line(range: range, text: text, size: size, isBlank: text.isEmpty))
        }
        guard lines.contains(where: { !$0.isBlank }) else { return [] }

        // Merge consecutive same-size lines into a paragraph. A blank line, a size
        // change, or a bullet starts a new block.
        var blocks: [[Line]] = []
        for line in lines {
            guard !line.isBlank else { blocks.append([]); continue }
            if var last = blocks.last, let previous = last.last,
               !Self.isBullet(line.text), !Self.isBullet(previous.text),
               abs(previous.size - line.size) < 0.5 {
                last.append(line)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append([line])
            }
        }

        return blocks.compactMap { block -> DraftElement? in
            guard let first = block.first, let last = block.last else { return nil }
            let text = block.map(\.text).joined(separator: " ").trimmed
            guard !text.isEmpty else { return nil }

            let span = NSRange(location: first.range.location,
                               length: NSMaxRange(last.range) - first.range.location)
            let box = boundingBox(of: span, on: page, in: bounds)

            let (kind, depth) = Self.classify(text, size: first.size, bodySize: bodySize)
            return DraftElement(kind, text, page: pageNumber, box: box, depth: depth)
        }
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

    // MARK: - Rasterize

    private func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = ocrDPI / 72.0
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
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
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Shared with the rich-text reader so both agree on what a heading looks like.
    ///
    /// Size wins over numbering: "14. Early Termination" set larger than the body is a
    /// heading, not a list item. Contracts and leases number their sections, and getting
    /// this backwards flattens a document's whole structure.
    static func classify(_ text: String, size: CGFloat, bodySize: CGFloat)
        -> (kind: ElementKind, depth: Int)
    {
        if bodySize > 0 {
            if size >= bodySize * 1.45 { return (.title, 0) }
            if size >= bodySize * 1.15 { return (.title, 1) }
        }
        if isBullet(text) { return (.listItem, 0) }
        return (.text, 0)
    }

    static func isBullet(_ text: String) -> Bool {
        text.starts(with: "•") || text.starts(with: "- ") || text.starts(with: "* ")
            || text.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

}
