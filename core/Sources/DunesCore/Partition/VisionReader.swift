import Foundation
import Vision
import CoreGraphics

/// Reads a page image with Vision's document recognizer.
///
/// This one call covers what would otherwise be a layout model, a table-structure
/// model, and an OCR engine: it returns a title, paragraphs in reading order, real
/// table cells, list items, and word-level coordinates — on-device, offline.
enum VisionReader {

    /// Recognize one page image and return elements in reading order.
    /// - Parameter page: 1-based page number stamped onto every element.
    static func read(image: CGImage, page: Int?) async throws -> [DraftElement] {
        // Defaults are what we want: accurate recognition with automatic language detection.
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: image)
        guard let container = observations.first?.document else { return [] }

        // Tables and paragraphs overlap — a cell's text also shows up as a paragraph.
        // Emit tables whole, and drop any paragraph sitting inside one.
        let tableBoxes = container.tables.map { box(of: $0.boundingRegion) }

        var placed: [(y: Double, x: Double, element: DraftElement)] = []

        if let title = container.title, !title.transcript.trimmed.isEmpty {
            let b = box(of: title.boundingRegion)
            placed.append((b.y, b.x, DraftElement(.title, title.transcript.trimmed,
                                                  page: page, box: b, depth: 0)))
        }

        let titleText = container.title?.transcript.trimmed
        for paragraph in container.paragraphs {
            let text = paragraph.transcript.trimmed
            guard !text.isEmpty, text != titleText else { continue }
            let b = box(of: paragraph.boundingRegion)
            guard !tableBoxes.contains(where: { $0.contains(b) }) else { continue }
            placed.append((b.y, b.x, DraftElement(.text, text, page: page, box: b,
                                                  confidence: confidence(of: paragraph))))
        }

        for list in container.lists {
            for item in list.items {
                let text = item.itemString.trimmed
                guard !text.isEmpty else { continue }
                let b = box(of: list.boundingRegion)
                placed.append((b.y, b.x, DraftElement(.listItem, text, page: page, box: b)))
            }
        }

        for table in container.tables {
            let b = box(of: table.boundingRegion)
            let rows = table.rows.map { row in
                row.map { $0.content.text.transcript.trimmed.replacingOccurrences(of: "\n", with: " ") }
            }
            guard !rows.isEmpty else { continue }
            placed.append((b.y, b.x, DraftElement(.table, markdownTable(rows), page: page, box: b)))
        }

        // Reading order: top to bottom, then left to right. Rows within ~1.5% of the
        // same height are treated as the same line.
        placed.sort { a, b in
            abs(a.y - b.y) < 0.015 ? a.x < b.x : a.y < b.y
        }
        return placed.map(\.element)
    }

    /// Vision reports normalized rects with a bottom-left origin; ours are top-left.
    /// `verticallyFlipped()` is the whole conversion — done here so no caller has to think about it.
    private static func box(of region: NormalizedRegion) -> BBox {
        let r = region.boundingBox.verticallyFlipped().cgRect
        return BBox(x: Double(r.origin.x), y: Double(r.origin.y),
                    width: Double(r.width), height: Double(r.height))
    }

    private static func confidence(of text: DocumentObservation.Container.Text) -> Double? {
        let scores = text.lines.compactMap { $0.topCandidates(1).first?.confidence }
        guard !scores.isEmpty else { return nil }
        return Double(scores.reduce(0, +) / Float(scores.count))
    }

    /// Tables are stored as markdown so the rendition can drop them in unchanged.
    static func markdownTable(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        let width = rows.map(\.count).max() ?? header.count
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: max(0, width - cells.count))
            return "| " + padded.map { $0.isEmpty ? " " : $0 }.joined(separator: " | ") + " |"
        }
        var out = [line(header), "|" + String(repeating: " --- |", count: width)]
        out.append(contentsOf: rows.dropFirst().map(line))
        return out.joined(separator: "\n")
    }
}

extension BBox {
    /// True when `other` sits (mostly) inside this box — used to drop paragraphs
    /// that duplicate table cells.
    func contains(_ other: BBox) -> Bool {
        let cx = other.x + other.width / 2
        let cy = other.y + other.height / 2
        return cx >= x && cx <= x + width && cy >= y && cy <= y + height
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
