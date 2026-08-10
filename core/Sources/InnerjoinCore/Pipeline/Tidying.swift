import Foundation

/// Repairs that every reader benefits from, applied once between parsing and storage.
///
/// Both of these were found by running real documents through the pipeline — a résumé
/// and a university handbook. Neither shows up in text you generate yourself, because
/// you don't accidentally write typographic ligatures or flatten your own bullet lists.
public enum Tidying {

    public static func clean(_ drafts: [DraftElement]) -> [DraftElement] {
        drafts.flatMap { splitInlineBullets($0) }.map { draft in
            var fixed = draft
            fixed.text = repairLigatures(draft.text)
            return fixed
        }
    }

    /// Turns typographic ligatures back into the letters they stand for.
    ///
    /// Word, InDesign and LaTeX emit "eﬃciency" as a single glyph. It looks identical
    /// on screen and is a completely different string: searching for "efficiency"
    /// finds nothing, and a model reading it sees a word it has never seen. Targeted
    /// replacement rather than full compatibility normalization, which would also
    /// rewrite fractions, superscripts and symbols that carry meaning.
    public static func repairLigatures(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0xFB00 && $0.value <= 0xFB06 })
                || text.contains("\u{0132}") || text.contains("\u{0133}")
        else { return text }

        var out = text
        for (ligature, letters) in ligatures {
            out = out.replacingOccurrences(of: ligature, with: letters)
        }
        return out
    }

    private static let ligatures: [(String, String)] = [
        ("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"),
        ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl"), ("\u{FB05}", "st"), ("\u{FB06}", "st"),
        ("\u{0132}", "IJ"), ("\u{0133}", "ij"),
    ]

    /// Splits a paragraph that is really a flattened bullet list.
    ///
    /// PDF text extraction routinely returns "● first point ● second point ● third"
    /// as one run, because the bullets and the text sit on the same line objects. Left
    /// alone it becomes a single wall of prose where a reader — human or model — sees
    /// no list at all, and no individual point can be cited.
    public static func splitInlineBullets(_ draft: DraftElement) -> [DraftElement] {
        // Tables and code have their own structure; never take them apart.
        guard draft.kind == .text || draft.kind == .listItem else { return [draft] }

        let text = draft.text
        // A flattened list begins with its first marker. A line like
        // "email • phone • linkedin" uses the same character as a *separator*, and
        // splitting that turns one contact line into three meaningless list items.
        guard let first = text.trimmed.first, bulletMarkers.contains(first) else { return [draft] }
        var pieces: [String] = []
        var current = ""
        var index = text.startIndex
        var found = 0

        while index < text.endIndex {
            let character = text[index]
            if bulletMarkers.contains(character) {
                // A marker only starts a new point if something precedes it; a leading
                // bullet is just this item's own marker.
                if !current.trimmed.isEmpty {
                    pieces.append(current)
                    found += 1
                }
                current = ""
                index = text.index(after: index)
                continue
            }
            current.append(character)
            index = text.index(after: index)
        }
        if !current.trimmed.isEmpty { pieces.append(current) }

        // One marker is an ordinary bullet, already handled. Two or more mean a list
        // was flattened into a paragraph.
        guard found >= 2 else { return [draft] }

        return pieces.compactMap { piece in
            let cleaned = piece.trimmed
            // Fragments left by a stray marker aren't worth a line of their own.
            guard cleaned.count > 2 else { return nil }
            var item = draft
            item.kind = .listItem
            item.text = cleaned
            return item
        }
    }

    /// The marks documents actually use for bullets.
    private static let bulletMarkers: Set<Character> = ["●", "•", "▪", "◦", "‣", "·"]
}
