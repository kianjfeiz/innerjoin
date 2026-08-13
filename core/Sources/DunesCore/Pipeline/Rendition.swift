import Foundation

/// Turns elements into one clean markdown document — the text a model reads.
///
/// Two jobs beyond formatting: drop repeated page furniture that wastes tokens, and
/// leave `[eN]` anchors on facts so an answer can point back at where it came from.
public enum Rendition {

    /// Anchors go on elements likely to carry a citable fact — tables, and anything
    /// containing a number, date, or amount. Anchoring every paragraph would cost
    /// tokens and pull attention for no gain.
    private static let factPattern = try! NSRegularExpression(
        pattern: #"\d{4}-\d{2}-\d{2}|[$€£]\s?[\d,]+|\b\d[\d,]*\.?\d*\s*(%|USD|EUR|GBP)\b|\b\d{1,3}(,\d{3})+\b|\b(19|20)\d{2}\b"#
    )

    public static func render(_ elements: [Element]) -> String {
        var lines: [String] = []
        var lastPage: Int?

        for element in elements {
            // Repeated furniture: no information, pure token cost.
            switch element.kind {
            case .pageHeader, .pageFooter, .pageNumber: continue
            default: break
            }

            // Invisible to a reader, useful to a model deciding which page a fact came from.
            if let page = element.page, page != lastPage {
                lines.append("<!-- page \(page) -->")
                lastPage = page
            }

            let anchor = deservesAnchor(element) ? " [\(element.tag)]" : ""
            let text = element.text.trimmed
            guard !text.isEmpty else { continue }

            switch element.kind {
            case .title:
                let hashes = String(repeating: "#", count: min(6, element.depth + 1))
                lines.append("\(hashes) \(text)\(anchor)")
            case .listItem:
                lines.append("- \(text)\(anchor)")
            case .table:
                lines.append(text + (anchor.isEmpty ? "" : "\n\(anchor.trimmed)"))
            case .code:
                lines.append("```\n\(text)\n```")
            case .image:
                lines.append("_[image: \(text)]_")
            case .caption:
                lines.append("_\(text)_")
            default:
                lines.append(text + anchor)
            }
        }

        return lines.joined(separator: "\n\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmed
    }

    private static func deservesAnchor(_ element: Element) -> Bool {
        if element.kind == .table { return true }
        let range = NSRange(element.text.startIndex..., in: element.text)
        return factPattern.firstMatch(in: element.text, range: range) != nil
    }

    /// Rough token count — good enough to decide whether a document needs splitting.
    public static func tokenEstimate(_ markdown: String) -> Int {
        Int(Double(markdown.count) / 3.7)
    }
}
