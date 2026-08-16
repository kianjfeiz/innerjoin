import Foundation

/// Bringing what a server returns into the library.
///
/// Deliberately the long way round: tool output is written to a markdown file on disk and
/// then handed to the ordinary `Ingest`. Nothing about extraction, anchors, citations,
/// dedup or the agenda needs to know MCP exists, and a message from Gmail becomes exactly
/// the same kind of thing as a PDF someone dropped in — answerable, citable, and countable
/// against the same "it's all on this Mac" promise, because now it is.
///
/// The alternative was a second ingest path that skipped the file. It would have been
/// shorter and it would have meant two definitions of what a document is.
public extension MCP {

    /// One thing to be written down.
    struct Draft: Sendable, Equatable {
        public let name: String
        public let markdown: String

        public init(name: String, markdown: String) {
            self.name = name
            self.markdown = markdown
        }
    }

    /// Split a tool result into documents.
    ///
    /// One per text item, because a server that returns a list of messages returns them
    /// as separate content items and joining them would produce a single document whose
    /// dates and people belong to a dozen different emails.
    static func drafts(from result: ToolResult, server: String, tool: String) -> [Draft] {
        let texts = result.content
            .filter { $0.kind == "text" }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return texts.enumerated().map { index, text in
            Draft(
                name: filename(for: text, server: server, tool: tool, index: index),
                markdown: text
            )
        }
    }

    /// A filename a person could find later.
    ///
    /// Taken from the content — a subject line, a heading, the first sentence — because
    /// `gmail-search-3.md` tells nobody anything, and the library shows documents by
    /// name. Falls back to the server and tool when the content offers nothing.
    static func filename(for text: String, server: String, tool: String, index: Int) -> String {
        let firstUseful = text
            .components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                let bare = line.drop { $0 == "#" || $0 == " " || $0 == "*" }
                return bare.count >= 3
            }?
            .drop { $0 == "#" || $0 == " " || $0 == "*" }

        let title = firstUseful.map(String.init) ?? "\(server)-\(tool)-\(index + 1)"
        let cleaned = title
            .replacingOccurrences(of: "Subject:", with: "", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let short = cleaned.count > 70 ? String(cleaned.prefix(70)).trimmingCharacters(in: .whitespaces)
                                       : cleaned
        return (short.isEmpty ? "\(server)-\(tool)-\(index + 1)" : short) + ".md"
    }

    /// Where pulled material is kept: inside the workspace, beside the library it feeds,
    /// one folder per server so it is obvious what came from where and what to delete.
    static func folder(for server: String, in workspace: URL) -> URL {
        workspace.appendingPathComponent("mcp").appendingPathComponent(server)
    }

    /// Write the drafts and read them in. Returns what landed on disk.
    ///
    /// Ingest hashes file contents, so pulling the same messages twice adds nothing the
    /// second time — which is what makes this safe to run on a schedule.
    @discardableResult
    static func write(_ drafts: [Draft], for server: String, in workspace: URL) throws -> [URL] {
        let folder = folder(for: server, in: workspace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []
        var used = Set<String>()
        for draft in drafts {
            // Two messages with the same subject are common; a suffix keeps both rather
            // than letting the second overwrite the first.
            var name = draft.name
            var attempt = 2
            while used.contains(name.lowercased()) {
                let base = draft.name.replacingOccurrences(of: ".md", with: "")
                name = "\(base) (\(attempt)).md"
                attempt += 1
            }
            used.insert(name.lowercased())

            let url = folder.appendingPathComponent(name)
            try Data(draft.markdown.utf8).write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }
}
