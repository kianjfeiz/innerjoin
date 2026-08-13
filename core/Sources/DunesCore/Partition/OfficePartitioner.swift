import Foundation
import UniformTypeIdentifiers

/// Reads the zipped-XML Office formats: spreadsheets and slide decks.
///
/// Both are a ZIP of XML parts, so one small unzipper serves both and the app avoids
/// a third-party archive dependency. Word documents are handled elsewhere by
/// `NSAttributedString`, which already knows them.
public struct OfficePartitioner: Partitioner {
    public init() {}

    private static let spreadsheet = UTType("org.openxmlformats.spreadsheetml.sheet")
    private static let presentation = UTType("org.openxmlformats.presentationml.presentation")

    public func handles(_ type: UTType) -> Bool {
        if let sheet = Self.spreadsheet, type.conforms(to: sheet) { return true }
        if let deck = Self.presentation, type.conforms(to: deck) { return true }
        return ["xlsx", "pptx"].contains(type.preferredFilenameExtension ?? "")
    }

    public func partition(fileAt url: URL) async throws -> PartitionOutput {
        let archive = try Zip(url: url)
        let names = archive.entryNames

        if names.contains(where: { $0.hasPrefix("xl/") }) {
            return try spreadsheetOutput(archive)
        }
        if names.contains(where: { $0.hasPrefix("ppt/slides/") }) {
            return try deckOutput(archive)
        }
        throw PartitionError.unsupported("this Office file")
    }

    // MARK: - Spreadsheets

    private func spreadsheetOutput(_ archive: Zip) throws -> PartitionOutput {
        // Cell text is pooled in one shared table and referenced by index; without it
        // every string cell reads as a number.
        let shared = try archive.text(of: "xl/sharedStrings.xml").map(Self.sharedStrings) ?? []

        var elements: [DraftElement] = []
        var sheets = 0
        for name in archive.entryNames.filter({ $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }).sorted() {
            guard let xml = try archive.text(of: name) else { continue }
            let rows = Self.sheetRows(xml, shared: shared)
            guard !rows.isEmpty else { continue }
            sheets += 1
            elements.append(DraftElement(.title, "Sheet \(sheets)", depth: 1))
            elements.append(DraftElement(.table, VisionReader.markdownTable(Array(rows.prefix(500)))))
            if rows.count > 500 {
                elements.append(DraftElement(.text, "(\(rows.count - 500) further rows not shown)"))
            }
        }
        guard !elements.isEmpty else { throw PartitionError.empty }
        return PartitionOutput(elements: elements, pageCount: sheets)
    }

    /// The shared string table, in document order — cells refer to it by position.
    static func sharedStrings(_ xml: String) -> [String] {
        Self.matches(#"<si>([\s\S]*?)</si>"#, in: xml).map { entry in
            Self.matches(#"<t[^>]*>([\s\S]*?)</t>"#, in: entry, group: 1)
                .joined()
                .decodedXML
        }
    }

    /// Rows of cells, with gaps preserved so columns stay aligned. A cell's column
    /// letter is what places it — spreadsheets omit empty cells entirely.
    static func sheetRows(_ xml: String, shared: [String]) -> [[String]] {
        var rows: [[String]] = []
        for row in Self.matches(#"<row[^>]*>([\s\S]*?)</row>"#, in: xml) {
            var cells: [Int: String] = [:]
            for cell in Self.matches(#"<c\b[^>]*?(?:/>|>[\s\S]*?</c>)"#, in: row) {
                let reference = Self.attribute("r", in: cell) ?? ""
                let column = Self.columnIndex(reference)
                let isShared = Self.attribute("t", in: cell) == "s"
                let raw = Self.matches(#"<v>([\s\S]*?)</v>"#, in: cell, group: 1).first
                    ?? Self.matches(#"<t[^>]*>([\s\S]*?)</t>"#, in: cell, group: 1).first
                guard let raw else { continue }
                if isShared, let index = Int(raw), shared.indices.contains(index) {
                    cells[column] = shared[index]
                } else {
                    cells[column] = raw.decodedXML
                }
            }
            guard let width = cells.keys.max() else { rows.append([]); continue }
            rows.append((0...width).map { cells[$0] ?? "" })
        }
        // Trailing blank rows carry nothing.
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        return rows
    }

    /// "BC12" → column 54. Spreadsheet columns are base-26 letters.
    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(0, index - 1)
    }

    // MARK: - Decks

    private func deckOutput(_ archive: Zip) throws -> PartitionOutput {
        var elements: [DraftElement] = []
        // slide2.xml sorts before slide10.xml unless the numbers are compared.
        let slides = archive.entryNames
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { Self.slideNumber($0) < Self.slideNumber($1) }

        for (index, name) in slides.enumerated() {
            guard let xml = try archive.text(of: name) else { continue }
            // Each <a:p> is a paragraph; the runs inside it are styled fragments.
            let paragraphs = Self.matches(#"<a:p>([\s\S]*?)</a:p>"#, in: xml).map { paragraph in
                Self.matches(#"<a:t>([\s\S]*?)</a:t>"#, in: paragraph, group: 1)
                    .joined().decodedXML.trimmed
            }.filter { !$0.isEmpty }
            guard !paragraphs.isEmpty else { continue }

            // The first line of a slide is nearly always its heading.
            elements.append(DraftElement(.title, paragraphs[0], page: index + 1, depth: 1))
            for line in paragraphs.dropFirst() {
                elements.append(DraftElement(.listItem, line, page: index + 1))
            }
        }
        guard !elements.isEmpty else { throw PartitionError.empty }
        return PartitionOutput(elements: elements, pageCount: slides.count)
    }

    static func slideNumber(_ path: String) -> Int {
        Int(path.replacingOccurrences(of: "ppt/slides/slide", with: "")
            .replacingOccurrences(of: ".xml", with: "")) ?? 0
    }

    // MARK: - Tiny XML helpers
    //
    // A real parser is overkill here: Office XML is machine-generated and regular, and
    // we only need text out of known tags.

    static func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: group), in: text).map { String(text[$0]) } }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        matches("\(name)=\"([^\"]*)\"", in: tag, group: 1).first
    }
}

extension String {
    /// XML's five predefined entities, which is all Office emits.
    var decodedXML: String {
        replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
