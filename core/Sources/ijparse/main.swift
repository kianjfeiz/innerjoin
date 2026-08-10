import Foundation
import ArgumentParser
import InnerjoinCore

@main
struct IJParse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ijparse",
        abstract: "innerjoin's on-device preprocessor — read files into markdown and elements.",
        subcommands: [Add.self, Show.self, List.self, Find.self],
        defaultSubcommand: Add.self
    )
}

struct WorkspaceOption: ParsableArguments {
    @Option(name: [.customShort("w"), .long], help: "Workspace folder.")
    var workspace: String = "~/Library/Application Support/innerjoin/Personal"

    var url: URL { URL(fileURLWithPath: (workspace as NSString).expandingTildeInPath) }
    func open() throws -> Store { try Store(root: url) }
}

// MARK: - add

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add files or folders to the library.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "Files or folders to read.") var paths: [String]
    @Flag(help: "Print the markdown of each file after reading it.") var markdown = false
    @Flag(help: "Print the elements as JSON after reading each file.") var json = false

    mutating func run() async throws {
        let store = try workspace.open()
        let ingest = Ingest(store: store)
        let started = Date()
        var added = 0, skipped = 0, failed = 0

        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let results = isDirectory
                ? try await ingest.addContents(of: url)
                : [try await ingest.add(fileAt: url)]

            for result in results {
                let document = result.document
                if result.wasAlreadyPresent {
                    skipped += 1
                    print("  already have  \(document.name)")
                    continue
                }
                switch document.status {
                case .failed:
                    failed += 1
                    print("  couldn't read \(document.name) — \(document.problem ?? "unknown reason")")
                case .partial:
                    added += 1
                    print("  read          \(document.name)  \(result.elementCount) parts · \(document.problem ?? "")")
                case .ok:
                    added += 1
                    let pages = document.pageCount.map { "\($0)p · " } ?? ""
                    print("  read          \(document.name)  \(pages)\(result.elementCount) parts")
                }
                if markdown, let text = document.markdown { print("\n\(text)\n") }
                if json, let id = document.id {
                    let elements = try store.elements(of: id)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? encoder.encode(elements),
                       let text = String(data: data, encoding: .utf8) { print(text) }
                }
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "\n%d added · %d already present · %d failed · %.2fs",
                     added, skipped, failed, elapsed))
    }
}

// MARK: - show

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print one document's markdown or elements.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "Document id.") var id: Int64
    @Flag(help: "Print elements as JSON instead of markdown.") var json = false

    mutating func run() async throws {
        let store = try workspace.open()
        guard let document = try store.document(id: id) else {
            throw ValidationError("No document with id \(id).")
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(try store.elements(of: id))
            print(String(data: data, encoding: .utf8) ?? "")
        } else {
            print(document.markdown ?? "(not rendered)")
        }
    }
}

// MARK: - list

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List documents in the library.")

    @OptionGroup var workspace: WorkspaceOption
    @Option(help: "How many to show.") var limit: Int = 50

    mutating func run() async throws {
        let store = try workspace.open()
        let documents = try store.recentDocuments(limit: limit)
        let counts = try store.counts()
        guard !documents.isEmpty else {
            print("Nothing here yet. Add files with: ijparse add <path>")
            return
        }
        for document in documents {
            let id = String(document.id ?? 0).padding(toLength: 5, withPad: " ", startingAt: 0)
            let mark = document.status == .failed ? "!" : (document.status == .partial ? "~" : " ")
            let pages = document.pageCount.map { "\($0)p" } ?? "—"
            print("\(id)\(mark) \(document.name.padded(48)) \(pages.padded(5)) \(document.stage.rawValue)")
        }
        print("\n\(counts.documents) documents · \(counts.elements) parts")
    }
}

// MARK: - find

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full-text search the library. Works with no model.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "What to look for.") var query: [String]

    mutating func run() async throws {
        let store = try workspace.open()
        let text = query.joined(separator: " ")
        let hits = try store.search(text)
        guard !hits.isEmpty else { print("Nothing matched \"\(text)\"."); return }
        for document in hits {
            print("\(String(document.id ?? 0).padded(5)) \(document.name)")
            if let markdown = document.markdown, let snippet = snippet(of: markdown, around: text) {
                print("      …\(snippet)…")
            }
        }
        print("\n\(hits.count) match\(hits.count == 1 ? "" : "es")")
    }

    private func snippet(of markdown: String, around query: String, width: Int = 90) -> String? {
        guard let first = query.split(separator: " ").first,
              let range = markdown.range(of: String(first), options: .caseInsensitive)
        else { return nil }
        let start = markdown.index(range.lowerBound, offsetBy: -min(30, markdown.distance(from: markdown.startIndex, to: range.lowerBound)))
        let end = markdown.index(range.lowerBound, offsetBy: min(width, markdown.distance(from: range.lowerBound, to: markdown.endIndex)))
        return markdown[start..<end].replacingOccurrences(of: "\n", with: " ")
    }
}

extension String {
    func padded(_ length: Int) -> String {
        count >= length ? String(prefix(length)) : padding(toLength: length, withPad: " ", startingAt: 0)
    }
}
