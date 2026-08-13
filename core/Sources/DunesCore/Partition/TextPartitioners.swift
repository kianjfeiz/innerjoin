import Foundation
import AppKit
import UniformTypeIdentifiers

/// Plain text, Markdown, CSV, and anything else that's just characters.
public struct PlainTextPartitioner: Partitioner {
    public init() {}

    public func handles(_ type: UTType) -> Bool {
        type.conforms(to: .plainText) || type.conforms(to: .text)
            || type.conforms(to: .commaSeparatedText) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .yaml)
    }

    public func partition(fileAt url: URL) async throws -> PartitionOutput {
        guard let raw = readText(at: url) else {
            throw PartitionError.unreadable("This file isn't readable as text.")
        }
        guard !raw.trimmed.isEmpty else { throw PartitionError.empty }

        let type = UTType(filenameExtension: url.pathExtension) ?? .plainText
        if type.conforms(to: .commaSeparatedText) || url.pathExtension.lowercased() == "tsv" {
            return PartitionOutput(elements: [csvElement(raw, tabs: url.pathExtension.lowercased() == "tsv")])
        }
        return PartitionOutput(elements: markdownish(raw))
    }

    /// UTF-8, then UTF-16, then Latin-1 — enough to cover text files in the wild.
    private func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for encoding: String.Encoding in [.utf8, .utf16, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    /// Splits on blank lines, and recognizes Markdown headings and bullets so `.md`
    /// files keep their structure.
    private func markdownish(_ text: String) -> [DraftElement] {
        text.components(separatedBy: "\n\n").compactMap { block -> DraftElement? in
            let trimmed = block.trimmed
            guard !trimmed.isEmpty else { return nil }

            if trimmed.starts(with: "#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let title = trimmed.dropFirst(hashes).trimmed
                guard !title.isEmpty else { return nil }
                return DraftElement(.title, title, depth: max(0, hashes - 1))
            }
            if trimmed.starts(with: "- ") || trimmed.starts(with: "* ") || trimmed.starts(with: "• ") {
                return DraftElement(.listItem, String(trimmed.dropFirst(2)).trimmed)
            }
            if trimmed.starts(with: "```") {
                return DraftElement(.code, trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "`")).trimmed)
            }
            return DraftElement(.text, trimmed)
        }
    }

    /// Delimited files become one table element — the same markdown a spreadsheet would produce.
    private func csvElement(_ text: String, tabs: Bool) -> DraftElement {
        let separator: Character = tabs ? "\t" : ","
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(500)                       // a preview is enough; the file itself is in the vault
            .map { splitRow(String($0), separator: separator) }
        return DraftElement(.table, VisionReader.markdownTable(rows))
    }

    /// Handles quoted fields and escaped quotes.
    private func splitRow(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?

        while let char = pending ?? iterator.next() {
            pending = nil
            if char == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    inQuotes.toggle()
                }
            } else if char == separator && !inQuotes {
                fields.append(current.trimmed); current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmed)
        return fields
    }
}

/// Word documents, RTF, and HTML — all read natively by AppKit, no third-party
/// unzipping or XML walking required.
///
/// These formats have no page geometry, so elements carry no coordinates. Citations
/// for them open the document at a text match instead of drawing a box.
public struct RichTextPartitioner: Partitioner {
    public init() {}

    private static let types: [UTType] = [
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        .rtf,
        UTType("com.apple.rtfd"),
        .html,
    ].compactMap { $0 }

    public func handles(_ type: UTType) -> Bool {
        Self.types.contains { type.conforms(to: $0) }
    }

    public func partition(fileAt url: URL) async throws -> PartitionOutput {
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
                url: url,
                options: [.documentType: documentType(for: url)],
                documentAttributes: nil
            )
        } catch {
            throw PartitionError.unreadable("This document could not be read: \(error.localizedDescription)")
        }
        guard attributed.length > 0 else { throw PartitionError.empty }

        // Font size relative to the document's body size tells headings from paragraphs.
        var sizes: [CGFloat] = []
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let font = value as? NSFont { sizes.append(font.pointSize) }
        }
        let bodySize = sizes.sorted()[safe: sizes.count / 2] ?? 12

        let full = attributed.string as NSString
        var elements: [DraftElement] = []
        full.enumerateSubstrings(in: NSRange(location: 0, length: full.length),
                                 options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let text = full.substring(with: range).trimmed
            guard !text.isEmpty else { return }
            let size = (attributed.attribute(.font, at: range.location, effectiveRange: nil)
                        as? NSFont)?.pointSize ?? bodySize

            let (kind, depth) = PDFPartitioner.classify(text, size: size, bodySize: bodySize)
            elements.append(DraftElement(kind, text, depth: depth))
        }
        guard !elements.isEmpty else { throw PartitionError.empty }
        return PartitionOutput(elements: elements)
    }

    private func documentType(for url: URL) -> NSAttributedString.DocumentType {
        switch url.pathExtension.lowercased() {
        case "docx":        return .officeOpenXML
        case "rtf":         return .rtf
        case "rtfd":        return .rtfd
        case "html", "htm": return .html
        case "doc":         return .docFormat
        default:            return .plain
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
