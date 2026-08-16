import Foundation
import ArgumentParser
import DunesCore

@main
struct IJParse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dunes",
        abstract: "dunes's on-device preprocessor — read files into markdown and elements.",
        subcommands: [Add.self, Show.self, List.self, Find.self,
                      Understand.self, Record.self, Upcoming.self, Tasks.self, Who.self,
                      Graph.self, Tidy.self, Sort.self, Settle.self, Name.self,
                      Ask.self, Problems.self, Key.self, ShowPrompt.self,
                      MCPCommand.self],
        defaultSubcommand: Add.self
    )
}

struct WorkspaceOption: ParsableArguments {
    @Option(name: [.customShort("w"), .long], help: "Workspace folder.")
    var workspace: String = "~/Library/Application Support/dunes/Personal"

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
            print("Nothing here yet. Add files with: dunes add <path>")
            return
        }
        for document in documents {
            let id = String(document.id ?? 0).padding(toLength: 5, withPad: " ", startingAt: 0)
            let mark = document.status == .failed ? "!" : (document.status == .partial ? "~" : " ")
            let pages = document.pageCount.map { "\($0)p" } ?? "—"
            // The label, not the arrival name: once a document is understood it's listed
            // as what it is. `dunes name` shows both.
            print("\(id)\(mark) \(document.label.padded(48)) \(pages.padded(5)) \(document.stage.rawValue)")
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
        // Searches both layers: the words in the file, and what was understood from
        // it. Understood matches come first — a hit on an extracted amount beats one
        // buried in body text.
        let hits = try store.find(text)
        guard !hits.isEmpty else { print("Nothing matched \"\(text)\"."); return }

        for hit in hits {
            let mark = hit.matchedRecord ? "◆" : " "
            let title = hit.record?.title ?? hit.document.name
            print("\(String(hit.document.id ?? 0).padded(5))\(mark) \(title)")
            if hit.record != nil, title != hit.document.name {
                print("       in \(hit.document.name)")
            }
            if let markdown = hit.document.markdown, let snippet = snippet(of: markdown, around: text) {
                print("       …\(snippet)…")
            }
        }
        let understood = hits.filter(\.matchedRecord).count
        print("\n\(hits.count) match\(hits.count == 1 ? "" : "es")"
              + (understood > 0 ? " · ◆ \(understood) matched what was understood" : ""))
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
    @Option(help: "anthropic | openai | mock. Defaults to $DUNES_PROVIDER.") var provider: String?
    @Option(help: "Model identifier. Defaults to $DUNES_MODEL.") var model: String?
    @Option(name: .customLong("base-url"), help: "For local or third-party endpoints.") var baseURL: String?
    @Flag(name: .shortAndLong, help: "Show which entities were refused, and why.") var verbose = false

    mutating func run() async throws {
        let store = try workspace.open()
        var environment = ProcessInfo.processInfo.environment
        if let provider { environment["DUNES_PROVIDER"] = provider }
        if let model { environment["DUNES_MODEL"] = model }
        if let baseURL { environment["DUNES_BASE_URL"] = baseURL }

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
                if result.proposedAssertions > 0 || result.assertionCount > 0 {
                    notes.append("\(result.assertionCount)/\(result.proposedAssertions) facts kept")
                }
                if !result.anomalies.isEmpty {
                    notes.append("⚠︎ \(result.anomalies.count) problems")
                }
                if result.droppedCitations > 0 {
                    notes.append("\(result.droppedCitations) bad citations dropped")
                }
                if !result.refusedEntities.isEmpty {
                    notes.append("\(result.refusedEntities.count) entities refused")
                }
                print("  understood  \(name.padded(34)) \(result.record.title.padded(40)) \(notes.joined(separator: " · "))")
                if let renamed = result.name, renamed != name {
                    print("                now called: \(renamed)")
                }
                if verbose {
                    for refusal in result.refusedEntities { print("                refused: \(refusal)") }
                }
            } catch {
                failed += 1
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("  couldn't    \(name.padded(34)) \(reason)")
            }
        }
        let spend = await Meter.shared.snapshot()
        print("\n\(understood) understood · \(failed) failed")
        if spend.calls > 0 { print("\(spend.description)") }
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
            print("Nothing understood for document \(id) yet. Try: dunes understand \(id)")
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
        print("\n\(items.count) upcoming · \"·\" means dunes worked it out")
    }
}

// MARK: - tasks

struct Tasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What your files are waiting on you for. Check things off by number.")

    @OptionGroup var workspace: WorkspaceOption
    @Option(help: "How far ahead to look.") var days: Int = 365
    @Option(help: "How far back to keep showing what slipped.") var back: Int = 120
    @Flag(help: "Include what you've already finished.") var all = false
    @Option(help: "Finish the task at this number, as listed.") var done: Int?
    @Option(help: "Put a finished task back, by number. Use with --all.") var undo: Int?
    @Option(help: "Set a task aside, by number. It returns on its own.") var later: Int?
    @Option(help: "How long --later sets it aside for.") var forDays: Int = 7

    mutating func run() async throws {
        let store = try workspace.open()
        let agenda = Agenda(lookBackDays: back, lookAheadDays: days, includeSettled: all)
        var items = try agenda.items(store: store)

        if let index = done ?? undo ?? later {
            guard items.indices.contains(index - 1) else {
                throw ValidationError("No task \(index). There are \(items.count).")
            }
            let item = items[index - 1]
            if let later, index == later {
                // Start of day, so a week from Tuesday evening is Tuesday morning and
                // not an hour a person would never have chosen.
                let when = Calendar.current.startOfDay(
                    for: Calendar.current.date(byAdding: .day, value: forDays, to: Date()) ?? Date())
                try store.setTaskSnoozed(key: item.id, until: when)
                print("Later · \(item.title) · back on \(Record.day(when))")
            } else {
                try store.setTaskDone(key: item.id, done: done != nil)
                print("\(done != nil ? "Done" : "Back") · \(item.title)")
            }
            items = try agenda.items(store: store)
        }

        guard !items.isEmpty else {
            print(all ? "Nothing here yet." : "Nothing waiting on you.")
            return
        }

        var horizon: Commitment.Horizon?
        for (index, item) in items.enumerated() {
            let this = item.horizon()
            if this != horizon {
                print("\n\(this.title.uppercased())")
                horizon = this
            }
            let when = item.due.map(Record.day) ?? "     —    "
            let mark = item.isDone ? "x" : " "
            let note = item.derived ? " ·" : "  "
            print("[\(mark)] \(String(index + 1).padded(3)) \(when)\(note) "
                + "\(item.kind.label.padded(9)) \(item.title)")
        }
        let open = items.filter { !$0.isDone }.count
        print("\n\(open) waiting · \"·\" means dunes worked it out"
            + " · finish one with `dunes tasks --done <n>`")
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
        guard !entities.isEmpty else { print("No entities yet — run: dunes understand"); return }

        let query = name.joined(separator: " ").lowercased()
        if query.isEmpty {
            for entity in entities {
                let count = try store.records(linkedTo: entity.id ?? 0).count
                print("\(entity.name.padded(38)) \(entity.kind.rawValue.padded(9)) \(count) record\(count == 1 ? "" : "s")")
            }
            print("\n\(entities.count) found")
            return
        }
        // Search every spelling the person has appeared under, not just their own name:
        // someone first met as "J. Ramirez" must be findable by that.
        guard let match = try store.people(matching: query).first
                ?? entities.first(where: { $0.name.lowercased().contains(query) }) else {
            print("Nobody matching \"\(query)\".")
            return
        }
        let entityID = match.id ?? 0
        let profile = try Memory(store: store).profile(of: entityID)

        let span = [profile?.firstSeen, profile?.lastSeen].compactMap { $0 }.map(Record.day)
        let when = span.count == 2 && span[0] != span[1] ? "  ·  \(span[0]) – \(span[1])" : ""
        print("\(match.label)  (\(match.kind.rawValue))\(when)")

        if let profile, !profile.facts.isEmpty {
            print()
            for fact in profile.facts {
                let since = fact.since.map { " since \(Record.day($0))" } ?? ""
                let cite = fact.documentID.map { id in
                    fact.elementTag.map { " [d\(id):\($0)]" } ?? " [d\(id)]"
                } ?? ""
                print("  \(fact.predicate.rawValue.padded(12)) \(fact.value)\(since)\(cite)")
                // What it replaced. People change jobs, and hiding that would make the
                // profile quietly wrong the first time someone moves.
                for older in fact.previously {
                    let ended = older.on.map { " until \(Record.day($0))" } ?? ""
                    print("  \(" ".padded(12)) \(older.value)\(ended)")
                }
            }
        }
        let spellings = profile?.alsoKnownAs ?? match.aliases
        if !spellings.isEmpty { print("\n  known as     \(spellings.joined(separator: " · "))") }
        print()
        for record in try store.records(linkedTo: match.id ?? 0) {
            let when = record.happenedOn.map(Record.day) ?? "—"
            print("  \(when.padded(12)) \(record.title)")
        }
    }
}

// MARK: - tidy

struct Tidy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Merge duplicate entities and flag documents that disagree. No model needed.")

    @OptionGroup var workspace: WorkspaceOption

    mutating func run() async throws {
        let store = try workspace.open()
        let outcome = try await Consolidate(store: store).run()

        if outcome.merged.isEmpty {
            print("No duplicates found.")
        } else {
            print("merged")
            for merge in outcome.merged {
                print("  \(merge.absorbed.padded(30)) → \(merge.kept.padded(30)) \(merge.why)")
            }
        }
        guard !outcome.conflicts.isEmpty else { return }
        print("\nworth a look — two documents disagree")
        for conflict in outcome.conflicts {
            print("  \(conflict.field) · \(conflict.entity)")
            print("    \(conflict.older.title.padded(34)) \(conflict.older.value)")
            print("    \(conflict.newer.title.padded(34)) \(conflict.newer.value)  ← newer")
        }
    }
}

// MARK: - sort

struct Sort: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sort",
        abstract: "Re-derive categories from the shape of the graph. No model needed.")

    @OptionGroup var workspace: WorkspaceOption

    mutating func run() async throws {
        let store = try workspace.open()
        let outcome = try await DunesCore.Organize(store: store).run()

        guard !outcome.categories.isEmpty else {
            print("No clusters yet — needs at least \(DunesCore.Organize.minimumMembers) records that share entities.")
            print("\(outcome.holding) in \(DunesCore.Organize.holdingCategory)")
            return
        }
        for category in outcome.categories {
            print("  \(category.name.padded(30)) \(category.members)")
        }
        if outcome.holding > 0 {
            print("  \(DunesCore.Organize.holdingCategory.padded(30)) \(outcome.holding)")
        }
        if !outcome.ignoredHubs.isEmpty {
            // Worth surfacing: a hub is usually a sign extraction is naming scenery.
            print("\nignored as too common to be meaningful: \(outcome.ignoredHubs.joined(separator: ", "))")
        }
    }
}

// MARK: - settle

struct Settle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settle",
        abstract: "Re-read documents that describe things differently from their peers.")

    @OptionGroup var workspace: WorkspaceOption
    @Option(help: "anthropic | openai | mock.") var provider: String?
    @Option(help: "Model identifier.") var model: String?

    mutating func run() async throws {
        let store = try workspace.open()
        var environment = ProcessInfo.processInfo.environment
        if let provider { environment["DUNES_PROVIDER"] = provider }
        if let model { environment["DUNES_MODEL"] = model }
        let settings = ProviderSettings.fromEnvironment(environment)

        let refine = Refine(store: store, provider: settings.makeProvider())
        let before = try refine.coherence()
        let passes = try await refine.run()

        guard !passes.isEmpty else {
            print(String(format: "Nothing to settle — the library already agrees with itself (%.0f%%).",
                         before * 100))
            return
        }
        for (index, pass) in passes.enumerated() {
            print(String(format: "pass %d · re-read %d · %.0f%% → %.0f%%",
                         index + 1, pass.reread.count,
                         pass.coherenceBefore * 100, pass.coherenceAfter * 100))
            for name in pass.reread.prefix(8) { print("    \(name)") }
        }
        _ = try await DunesCore.Organize(store: store).run()
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

// MARK: - ask

struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ask a question about the library. Answers cite the documents they came from.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "The question.") var question: [String]
    @Option(help: "anthropic | openrouter | openai | ollama | mock. Defaults to $DUNES_PROVIDER.")
    var provider: String?
    @Option(help: "Model identifier. Defaults to $DUNES_MODEL.") var model: String?
    @Option(help: "How many documents to put in front of the model.") var breadth: Int = 8
    @Flag(name: .shortAndLong, help: "Show what retrieval found, and every citation.")
    var verbose = false

    mutating func run() async throws {
        let store = try workspace.open()
        var environment = ProcessInfo.processInfo.environment
        if let provider { environment["DUNES_PROVIDER"] = provider }
        if let model { environment["DUNES_MODEL"] = model }
        let settings = ProviderSettings.fromEnvironment(environment)

        let text = question.joined(separator: " ")
        let asker = DunesCore.Ask(store: store, provider: settings.makeProvider(),
                                     breadth: breadth)
        let answer = try await asker.answer(text)

        if verbose, !answer.consulted.isEmpty {
            print("consulted:")
            for document in answer.consulted {
                print("  \(document.matchedRecord ? "◆" : " ") d\(document.id)  \(document.label)")
            }
            print("")
        }

        // An unanswerable question is answered honestly, and looks different on screen.
        print(answer.answered ? answer.text : "— \(answer.text)")

        if !answer.citations.isEmpty {
            print("")
            for citation in answer.citations {
                let page = citation.page.map { " p\($0)" } ?? ""
                print("  [d\(citation.documentID):\(citation.elementTag)]\(page)  \(citation.documentLabel)")
                if verbose { print("      \"\(citation.quote)\"") }
            }
        }
        if answer.invented > 0 {
            print("\n  \(answer.invented) citation\(answer.invented == 1 ? "" : "s") pointed at nothing and were dropped.")
        }
        let spend = await Meter.shared.snapshot()
        if spend.calls > 0 { print("\n\(spend.description)") }
    }
}

// MARK: - problems

struct Problems: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "problems",
        abstract: "Documents that contradict themselves. The value is kept as printed; this says what doesn't add up.")

    @OptionGroup var workspace: WorkspaceOption

    mutating func run() async throws {
        let store = try workspace.open()
        let flagged = try store.flagged()
        guard !flagged.isEmpty else {
            print("Nothing questionable found.")
            return
        }
        for entry in flagged {
            print("\n\(entry.document.label)")
            for anomaly in entry.anomalies {
                let mark = anomaly.foundBy == .checked ? "✓" : "·"
                let where_ = anomaly.elementTag.map { " [\($0)]" } ?? ""
                print("  \(mark) \(anomaly.kind.rawValue.padded(16)) \(anomaly.detail)\(where_)")
            }
        }
        let total = flagged.reduce(0) { $0 + $1.anomalies.count }
        let checked = flagged.flatMap(\.anomalies).filter { $0.foundBy == .checked }.count
        print("\n\(total) in \(flagged.count) documents · \(checked) proved by rule, \(total - checked) reported by the reader")
    }
}

// MARK: - name

struct Name: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Names documents after what's in them. Originals are never touched.")

    @OptionGroup var workspace: WorkspaceOption
    @Flag(help: "Re-derive every name, rather than just showing them.") var refresh = false
    @Option(name: .customLong("export"), help: "Copy the library into a folder under its derived names.")
    var export: String?

    mutating func run() async throws {
        let store = try workspace.open()
        let namer = Namer(store: store)

        if refresh {
            let changed = try await namer.nameAll()
            print("\(changed) name\(changed == 1 ? "" : "s") changed\n")
        }

        if let export {
            let folder = URL(fileURLWithPath: (export as NSString).expandingTildeInPath)
            let written = try namer.export(to: folder)
            for file in written { print("  \(file.from.padded(40)) → \(file.to)") }
            print("\n\(written.count) file\(written.count == 1 ? "" : "s") copied to \(folder.path)")
            return
        }

        let documents = try store.allDocuments()
        guard !documents.isEmpty else {
            print("Nothing here yet. Add files with: dunes add <path>")
            return
        }
        for document in documents {
            let id = String(document.id ?? 0).padded(5)
            guard document.wasRenamed else {
                let why = document.stage == .understood ? "nothing better to call it" : "not understood yet"
                print("\(id) \(document.name.padded(46)) · \(why)")
                continue
            }
            print("\(id) \(document.name.padded(46)) → \(document.label)")
        }
        let renamed = documents.filter(\.wasRenamed).count
        print("\n\(renamed) of \(documents.count) named from their contents")
    }
}

// MARK: - key

struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Store an API key in the keychain. It never touches the database or the vault.",
        subcommands: [Set.self, Forget.self])

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a key for a provider. Reads it from stdin so it stays out of your shell history.")

        @Argument(help: "anthropic | openrouter | openai | groq | together | deepseek") var provider: String
        @Argument(help: "The key. Omit it — safer — and paste when prompted.") var key: String?
        @Option(help: "Model to verify against. Defaults to the provider's usual one.") var model: String?

        mutating func run() async throws {
            // A key passed as an argument is written to shell history and shows up in
            // `ps` output for as long as the process lives. Reading it from stdin keeps
            // it out of both. The argument stays supported for scripts, which have
            // their own reasons.
            let secret: String?
            if let key {
                secret = key
            } else {
                FileHandle.standardError.write(Data("Paste the key, then press return: ".utf8))
                secret = readLine(strippingNewline: true)
            }
            guard let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                throw ValidationError("No key given.")
            }
            let name = provider.lowercased()

            // Checked before it's stored, in two steps. The shape check is free and
            // catches the mistake that actually happens — a password pasted into a
            // prompt that asked for a key. The live call catches everything else. A
            // credential that was never valid must never be written anywhere; finding
            // out later means it sits in the keychain looking correct.
            if let complaint = ProviderError.lookWrong(trimmed, for: name) {
                throw ValidationError(complaint)
            }

            var environment = ProcessInfo.processInfo.environment
            environment["DUNES_PROVIDER"] = name
            environment["DUNES_API_KEY"] = trimmed
            if let model { environment["DUNES_MODEL"] = model }
            let settings = ProviderSettings.fromEnvironment(environment)

            print("Checking it against \(settings.makeProvider().label)…")
            do {
                _ = try await settings.makeProvider().extract(
                    system: "Reply with JSON only.",
                    user: "Return {\"ok\":true}",
                    schema: ["type": "object",
                             "properties": ["ok": ["type": "boolean"]],
                             "required": ["ok"]],
                    maxTokens: 16)
            } catch let error as ProviderError {
                switch error {
                case .http(let code, _) where code == 401 || code == 403:
                    throw ValidationError("The service rejected that key (\(code)). Nothing was saved.")
                case .http(let code, let body):
                    throw ValidationError("The service answered \(code): \(body.prefix(160))\nNothing was saved.")
                default:
                    // It authenticated but answered oddly — the key is fine, which is
                    // all this command is deciding.
                    break
                }
            }

            print(Keychain.write(trimmed, account: name)
                  ? "Verified and saved to the login keychain. It never touches the database or the vault."
                  : "The key works, but it couldn't be saved to the keychain.")
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


/// Print the system prompt exactly as it is sent.
///
/// Writing a voice is a loop — change it, ask something, read the answer, change it
/// again — and the loop is much shorter when you can see the actual bytes rather than
/// infer them from two files. Honours DUNES_VOICE, so an override can be checked before
/// it is trusted.
struct ShowPrompt: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompt",
        abstract: "Print the system prompt used to answer questions.")

    @Flag(name: .long, help: "Only the voice — the half that is meant to be rewritten.")
    var voiceOnly = false

    func run() throws {
        print(voiceOnly ? Voice.instructions : DunesCore.Ask.system)
    }
}

// MARK: - mcp

/// Connect to MCP servers.
///
/// Servers are written down in `mcp.json` inside the workspace, in the same shape every
/// other MCP client uses, so a server already configured elsewhere can be pasted in
/// whole:
///
///     {
///       "mcpServers": {
///         "gmail": {
///           "command": "npx",
///           "args": ["-y", "@some/gmail-mcp-server"],
///           "env": { "GMAIL_CREDENTIALS": "~/.gmail/credentials.json" }
///         }
///       }
///     }
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Connect to MCP servers and pull what they hold into the library.",
        subcommands: [MCPServers.self, MCPTools.self, MCPCall.self, MCPPull.self],
        defaultSubcommand: MCPServers.self)
}

struct MCPServers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "servers", abstract: "List the servers in mcp.json.")

    @OptionGroup var workspace: WorkspaceOption

    func run() throws {
        let configuration = try MCP.Configuration.load(from: workspace.url)
        guard !configuration.servers.isEmpty else {
            print("No servers. Write them in \(MCP.Configuration.url(in: workspace.url).path):")
            print("""

              {
                "mcpServers": {
                  "gmail": { "command": "npx", "args": ["-y", "<a-gmail-mcp-server>"] }
                }
              }

            """)
            return
        }
        for (name, server) in configuration.servers.sorted(by: { $0.key < $1.key }) {
            print("  \(name)  \(([server.command] + server.args).joined(separator: " "))")
        }
    }
}

struct MCPTools: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools", abstract: "Ask a server what it can do.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "Server name, as written in mcp.json.") var server: String
    @Flag(help: "Print each tool's input schema.") var schema = false

    func run() throws {
        let client = try connect(server, in: workspace.url)
        defer { client.stop() }
        let tools = try client.tools()
        guard !tools.isEmpty else { return print("  no tools") }
        for tool in tools {
            print("  \(tool.name)")
            if !tool.description.isEmpty {
                print("      \(tool.description.replacingOccurrences(of: "\n", with: " "))")
            }
            if schema { print(tool.schema.split(separator: "\n").map { "      \($0)" }.joined(separator: "\n")) }
        }
    }
}

struct MCPCall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "call", abstract: "Call one tool and print what comes back.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "Server name.") var server: String
    @Argument(help: "Tool name.") var tool: String
    @Option(name: .long, help: "Arguments as a JSON object.") var args: String = "{}"

    func run() throws {
        let client = try connect(server, in: workspace.url)
        defer { client.stop() }
        print(try client.call(tool, arguments: arguments(args)).text)
    }
}

/// Pull what a tool returns into the library.
///
/// Each text item becomes a markdown file under `mcp/<server>/` in the workspace and then
/// goes through the ordinary reader, so what arrives is a document like any other — same
/// extraction, same anchors, same citations. Ingest hashes contents, so pulling twice
/// adds nothing the second time.
struct MCPPull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull", abstract: "Call a tool and read the result into the library.")

    @OptionGroup var workspace: WorkspaceOption
    @Argument(help: "Server name.") var server: String
    @Argument(help: "Tool name.") var tool: String
    @Option(name: .long, help: "Arguments as a JSON object.") var args: String = "{}"
    @Flag(help: "Write the files but don't add them to the library.") var dryRun = false

    mutating func run() async throws {
        let client = try connect(server, in: workspace.url)
        defer { client.stop() }

        let result = try client.call(tool, arguments: arguments(args))
        let drafts = MCP.drafts(from: result, server: server, tool: tool)
        guard !drafts.isEmpty else { return print("  nothing came back") }

        let written = try MCP.write(drafts, for: server, in: workspace.url)
        print("  wrote \(written.count) file\(written.count == 1 ? "" : "s") to "
              + MCP.folder(for: server, in: workspace.url).path)
        guard !dryRun else { return }

        let ingest = Ingest(store: try workspace.open())
        var added = 0, already = 0
        for url in written {
            let outcome = try await ingest.add(fileAt: url)
            outcome.wasAlreadyPresent ? (already += 1) : (added += 1)
            print("  \(outcome.wasAlreadyPresent ? "already have" : "read        ") \(outcome.document.name)")
        }
        print("\n  \(added) added, \(already) already there. Run `dunes understand` to read them properly.")
    }
}

private func connect(_ name: String, in workspace: URL) throws -> MCPClient {
    let configuration = try MCP.Configuration.load(from: workspace)
    guard let server = configuration.servers[name] else {
        throw MCP.Failure.noSuchServer(name)
    }
    let client = MCPClient(name: name, config: server)
    try client.start()
    return client
}

private func arguments(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}
