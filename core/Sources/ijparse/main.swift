import Foundation
import ArgumentParser
import InnerjoinCore

@main
struct IJParse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ijparse",
        abstract: "innerjoin's on-device preprocessor — read files into markdown and elements.",
        subcommands: [Add.self, Show.self, List.self, Find.self,
                      Understand.self, Record.self, Upcoming.self, Who.self,
                      Graph.self, Key.self],
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

// MARK: - understand (Stage 3)

struct Understand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn read documents into records, entities, and dates. Needs a model.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "Document ids. Omit to do everything not yet understood.") var ids: [Int64] = []
    @Option(help: "anthropic | openai | mock. Defaults to $IJ_PROVIDER.") var provider: String?
    @Option(help: "Model identifier. Defaults to $IJ_MODEL.") var model: String?
    @Option(name: .customLong("base-url"), help: "For local or third-party endpoints.") var baseURL: String?
    @Flag(name: .shortAndLong, help: "Show which entities were refused, and why.") var verbose = false

    mutating func run() async throws {
        let store = try workspace.open()
        var environment = ProcessInfo.processInfo.environment
        if let provider { environment["IJ_PROVIDER"] = provider }
        if let model { environment["IJ_MODEL"] = model }
        if let baseURL { environment["IJ_BASE_URL"] = baseURL }

        let settings = ProviderSettings.fromEnvironment(environment)
        let distill = Distill(store: store, provider: settings.makeProvider())
        print("Using \(settings.makeProvider().label)\n")

        let targets = ids.isEmpty
            ? try store.recentDocuments(limit: 500)
                .filter { $0.stage == .rendered && $0.status != .failed }
                .compactMap(\.id)
            : ids
        guard !targets.isEmpty else { print("Nothing to understand."); return }

        var understood = 0, failed = 0
        for id in targets {
            let name = (try store.document(id: id))?.name ?? "\(id)"
            do {
                let result = try await distill.understand(documentID: id)
                understood += 1
                var notes = ["\(result.entityCount) entities", "\(result.dateCount) dates"]
                if result.droppedCitations > 0 {
                    notes.append("\(result.droppedCitations) bad citations dropped")
                }
                if !result.refusedEntities.isEmpty {
                    notes.append("\(result.refusedEntities.count) entities refused")
                }
                print("  understood  \(name.padded(34)) \(result.record.title.padded(40)) \(notes.joined(separator: " · "))")
                if verbose {
                    for refusal in result.refusedEntities { print("                refused: \(refusal)") }
                }
            } catch {
                failed += 1
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("  couldn't    \(name.padded(34)) \(reason)")
            }
        }
        print("\n\(understood) understood · \(failed) failed")
    }
}

// MARK: - record

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what was understood from a document.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "Document id.") var id: Int64

    mutating func run() async throws {
        let store = try workspace.open()
        guard let record = try store.record(ofDocument: id) else {
            print("Nothing understood for document \(id) yet. Try: ijparse understand \(id)")
            return
        }
        print(record.title)
        if let kind = record.kind { print("  kind      \(kind)") }
        if let category = record.category { print("  category  \(category)") }
        if let summary = record.summary { print("  summary   \(summary)") }
        if let amount = record.amount {
            print("  amount    \(amount) \(record.currency ?? "")")
        }

        if !record.fields.isEmpty {
            print("\n  fields")
            for (name, field) in record.fields.sorted(by: { $0.key < $1.key }) {
                let where_ = field.page.map { "p\($0)" } ?? (field.source ?? "—")
                print("    \(name.padded(22)) \(field.value.padded(38)) \(where_)")
            }
        }
        if let recordID = record.id {
            let dates = try store.dates(ofRecord: recordID)
            if !dates.isEmpty {
                print("\n  dates")
                for date in dates {
                    let mark = date.derived ? " (worked out)" : ""
                    print("    \(date.kind.padded(22)) \(Self.day(date.date))\(mark)")
                }
            }
            let links = try store.links(from: recordID)
            if !links.isEmpty {
                print("\n  linked to")
                for link in links {
                    let name = try entityName(link.dst, store: store)
                    print("    \(link.rel.padded(22)) \(name)")
                }
            }
        }
    }

    private func entityName(_ reference: String, store: Store) throws -> String {
        guard reference.hasPrefix("entity:"),
              let id = Int64(reference.dropFirst("entity:".count)) else { return reference }
        return try store.entities(limit: 1000).first { $0.id == id }?.name ?? reference
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - upcoming

struct Upcoming: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dates coming up, read out of your documents.")

    @OptionGroup var workspace: WorkspaceOption
    @Option(help: "How far ahead to look.") var days: Int = 365

    mutating func run() async throws {
        let store = try workspace.open()
        let items = try store.upcoming(withinDays: days)
        guard !items.isEmpty else { print("Nothing on the horizon."); return }
        let today = Date()
        for (date, record) in items {
            let away = Calendar.current.dateComponents([.day], from: today, to: date.date).day ?? 0
            let mark = date.derived ? "·" : " "
            print("\(Record.day(date.date))  \(String(away).padded(4))d \(mark) \(date.kind.padded(18)) \(record.title)")
        }
        print("\n\(items.count) upcoming · \"·\" means innerjoin worked it out")
    }
}

// MARK: - who

struct Who: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "People, organizations, and places found across your files.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "Name to look up. Omit to list everyone.") var name: [String] = []

    mutating func run() async throws {
        let store = try workspace.open()
        let entities = try store.entities(limit: 500)
        guard !entities.isEmpty else { print("No entities yet — run: ijparse understand"); return }

        let query = name.joined(separator: " ").lowercased()
        if query.isEmpty {
            for entity in entities {
                let count = try store.records(linkedTo: entity.id ?? 0).count
                print("\(entity.name.padded(38)) \(entity.kind.rawValue.padded(9)) \(count) record\(count == 1 ? "" : "s")")
            }
            print("\n\(entities.count) found")
            return
        }
        guard let match = entities.first(where: { $0.name.lowercased().contains(query) }) else {
            print("Nobody matching \"\(query)\".")
            return
        }
        print("\(match.name)  (\(match.kind.rawValue))")
        if !match.aliases.isEmpty { print("also seen as: \(match.aliases.joined(separator: ", "))") }
        print()
        for record in try store.records(linkedTo: match.id ?? 0) {
            let when = record.happenedOn.map(Record.day) ?? "—"
            print("  \(when.padded(12)) \(record.title)")
        }
    }
}

// MARK: - graph

struct Graph: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Is the knowledge graph healthy, or bloating?")

    @OptionGroup var workspace: WorkspaceOption

    mutating func run() async throws {
        let store = try workspace.open()
        let health = try store.graphHealth()
        guard health.records > 0 else { print("Nothing understood yet."); return }

        print("\(health.records) records · \(health.entities) entities · \(health.links) links")
        print(String(format: "%.1f entities per record", health.entitiesPerRecord))
        print(String(format: "%d singletons (%.0f%% of entities)",
                     health.singletons, health.singletonShare * 100))

        // Judgement, not just numbers — the point is to notice drift early.
        if health.entitiesPerRecord > 6 {
            print("\n⚠︎ More than six entities per record. Extraction is probably naming scenery.")
        }
        if health.singletonShare > 0.8 && health.entities > 20 {
            print("\n⚠︎ Most entities appear in only one file. Either the library is young,")
            print("  or names aren't being matched to each other.")
        }
        if !health.hubs.isEmpty {
            print("\nhubs — attached to much of the library, so they say little:")
            for hub in health.hubs {
                print(String(format: "  %@  %d records (%.0f%%)",
                             hub.name.padded(34), hub.records, hub.share * 100))
            }
        }
        if !health.relations.isEmpty {
            print("\nrelations")
            for relation in health.relations {
                print("  \(relation.name.padded(18)) \(relation.count)")
            }
        }
    }
}

// MARK: - key

struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Store an API key in the keychain. It never touches the database or the vault.",
        subcommands: [Set.self, Forget.self])

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a key for a provider.")
        @Argument(help: "anthropic | openai") var provider: String
        @Argument(help: "The key.") var key: String
        mutating func run() async throws {
            print(Keychain.write(key, account: provider.lowercased())
                  ? "Saved. innerjoin will use it automatically."
                  : "Couldn't save to the keychain.")
        }
    }

    struct Forget: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a stored key.")
        @Argument(help: "anthropic | openai") var provider: String
        mutating func run() async throws {
            Keychain.delete(account: provider.lowercased())
            print("Removed.")
        }
    }
}

extension String {
    func padded(_ length: Int) -> String {
        count >= length ? String(prefix(length)) : padding(toLength: length, withPad: " ", startingAt: 0)
    }
}
