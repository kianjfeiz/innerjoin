import Foundation
import DunesCore

/// The engine, adapted to a small window.
///
/// Every list this returns is a query against the real library — the same `Store` the CLI
/// writes. Nothing here is invented: people come from the entity graph, files from the
/// document table, and an answer from `Ask`, which refuses to say anything it can't cite.
final class Library: @unchecked Sendable {
    let workspace: URL

    init(workspace: URL = Library.defaultWorkspace) {
        self.workspace = workspace
    }

    /// The same folder the CLI writes, so `dunes add` and this app are two views of one
    /// library rather than two libraries.
    static var defaultWorkspace: URL {
        if let override = ProcessInfo.processInfo.environment["DUNES_WORKSPACE"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: ("~/Library/Application Support/dunes/Personal" as NSString)
            .expandingTildeInPath)
    }

    /// One `Store` for the app's lifetime, opened once behind a lock.
    ///
    /// Learned the hard way: two concurrent opens race the schema migrator and SQLite
    /// returns "database is locked". `Store` is built for concurrent *use*; it's
    /// concurrent *opening* that has to happen exactly once.
    private let lock = NSLock()
    private var cached: Store?
    private let settingsLock = NSLock()
    private var cachedSettings: ProviderSettings?

    private func open() throws -> Store {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let store = try Store(root: workspace)
        cached = store
        return store
    }

    // MARK: - What the panel shows

    /// A row in any of the browse lists. One shape for people, files and sources, so the
    /// list view never has to know which it's drawing.
    struct Row: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let detail: String?
        let symbol: String
        /// The question tapping this row asks. Every row is a way into the conversation
        /// rather than a dead end.
        let question: String
    }

    struct Snapshot: Sendable {
        var documents = 0
        var people = 0
        /// Things the library noticed that have a date or a contradiction attached —
        /// used for the prompts under the field, so they're real rather than canned.
        var prompts: [String] = []
        /// How much is waiting, and how much of it has already slipped. Shown on the
        /// way in: the point of noticing a deadline is telling someone before it
        /// passes, and a list nobody opens has not done that.
        var waiting = 0
        var overdue = 0
        var isEmpty: Bool { documents == 0 }
    }

    func snapshot() async throws -> Snapshot {
        let store = try open()
        var snapshot = Snapshot()
        snapshot.documents = try store.counts().documents
        guard snapshot.documents > 0 else { return snapshot }
        snapshot.people = try store.graphHealth().entities

        // Prompts are derived, never written by hand: a real deadline, a real
        // contradiction, a real name that keeps recurring.
        var prompts: [String] = []
        if let due = try store.upcoming(withinDays: 60).first {
            prompts.append("What happens with \(due.record.title)?")
        }
        if let flagged = try store.flagged(limit: 1).first {
            prompts.append("What doesn't add up in \(flagged.document.label)?")
        }
        if let hub = try store.graphHealth().hubs.first {
            prompts.append("What do I have about \(hub.name)?")
        }
        snapshot.prompts = Array(prompts.prefix(3))

        if let items = try? Agenda().items(store: store) {
            snapshot.waiting = items.count
            snapshot.overdue = items.filter { $0.horizon() == .overdue }.count
        }
        return snapshot
    }

    func people() async throws -> [Row] {
        let store = try open()
        return try store.entities(limit: 200)
            .filter { $0.kind == .person || $0.kind == .org }
            .map { entity in
                Row(
                    id: "e\(entity.id ?? 0)",
                    title: entity.label,
                    detail: entity.kind == .person ? "Person" : "Organization",
                    symbol: entity.kind == .person ? "person" : "building.2",
                    question: "What do I have about \(entity.label)?"
                )
            }
    }

    func files() async throws -> [Row] {
        let store = try open()
        return try store.allDocuments()
            .sorted { $0.addedAt > $1.addedAt }
            .map { document in
                let title = document.id
                    .flatMap { try? store.record(ofDocument: $0)?.title } ?? document.label
                return Row(
                    id: "d\(document.id ?? 0)",
                    title: title,
                    detail: document.stage == .understood ? "Understood" : "Read",
                    symbol: "doc",
                    question: "What is \(title) about?"
                )
            }
    }

    /// What the library is waiting on you for, in the order it wants attention.
    func tasks() async throws -> [Commitment] {
        let store = try open()
        let agenda = Agenda()
        let items = try agenda.items(store: store)
        // Decisions about commitments no document produces any more would otherwise
        // pile up forever. Cheap, and only ever drops keys nothing can resurrect.
        if let live = try? agenda.liveKeys(store: store) {
            _ = try? store.forgetTaskStates(keeping: live)
        }
        return items
    }

    /// Finish one, or put it back.
    func setTaskDone(_ key: String, done: Bool) async throws {
        try open().setTaskDone(key: key, done: done)
    }

    /// Set one aside. It returns on its own when the date passes.
    func snoozeTask(_ key: String, until: Date?) async throws {
        try open().setTaskSnoozed(key: key, until: until)
    }

    // MARK: - Answering

    /// A question, narrated as it runs. The narration is real — the counts are the
    /// actual counts and the documents are the ones retrieval actually read.
    func answer(_ question: String) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let store = try open()
                    // Not "Searching 10 files". Retrieval is a local FTS query that has
                    // already finished by the time anyone could read the words, and
                    // announcing it on every question told somebody asking about a film
                    // that their paperwork was being rifled through. The note that means
                    // something — "Reading 3 documents" — comes below, and only when
                    // documents were actually worth reading.
                    continuation.yield(.working("Thinking"))

                    let settings = providerSettings()
                    guard settings.apiKey?.isEmpty == false else {
                        continuation.yield(.text(
                            "I can search your files but I can't answer right now — "
                            + "there's no model connected to this build."))
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    let asker = Ask(store: store, provider: settings.makeProvider())
                    let answer = try await asker.answer(question)

                    if !answer.consulted.isEmpty {
                        continuation.yield(.working(
                            "Reading \(answer.consulted.count) document\(answer.consulted.count == 1 ? "" : "s")"))
                    }
                    continuation.yield(.text(answer.text))
                    for citation in answer.citations {
                        continuation.yield(.citation(
                            Citation(tag: citation.elementTag,
                                     document: citation.documentLabel,
                                     quote: citation.quote,
                                     documentID: citation.documentID)))
                    }
                    continuation.yield(.done)
                } catch {
                    continuation.yield(.text("That didn't work: \(error.localizedDescription)"))
                    continuation.yield(.done)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    enum Chunk: Sendable {
        case working(String)
        case text(String)
        case citation(Citation)
        case done
    }

    struct Citation: Identifiable, Hashable, Sendable {
        let id = UUID()
        let tag: String
        let document: String
        let quote: String
        /// Which document it points at, so the citation can be opened rather than only
        /// read. Without this a source is a label; with it, it's a door.
        let documentID: Int64
    }

    /// A document, as something to look at.
    ///
    /// The markdown rendition rather than the original bytes: it is what the model was
    /// actually shown, so a person checking a citation sees the same text the answer was
    /// built from — which is the only version where checking means anything. The original
    /// file is one button away for when they want the real thing.
    struct Preview: Identifiable, Equatable, Sendable {
        let id: Int64
        let name: String
        let text: String
        let file: URL?
        /// The element the citation pointed at, so the preview can open on it.
        let focus: String?
    }

    func preview(documentID: Int64, focus: String?) async throws -> Preview? {
        let store = try open()
        guard let document = try store.document(id: documentID) else { return nil }
        let file = store.vault.url(for: document.vaultPath)
        let text = try document.markdown ?? store.elements(of: documentID)
            .map(\.text)
            .joined(separator: "\n\n")
        return Preview(
            id: documentID,
            name: document.displayName ?? document.name,
            text: text,
            file: FileManager.default.fileExists(atPath: file.path) ? file : nil,
            focus: focus
        )
    }

    /// Where the app gets its credential, which is not from the person using it.
    ///
    /// Model calls are the product's to make, so there is no key of theirs to find. In
    /// order: the environment, for the harness and for a developer running from source;
    /// then `DUNESAPIKey` in the bundle's Info.plist, which is where a build carries the
    /// credential it ships with. The login keychain is not consulted at all — see
    /// `ProviderSettings.fromEnvironment(_:keychain:)` for why that lookup was doing
    /// nothing but producing password dialogs.
    ///
    /// Read once per launch and kept, failures included: a lookup that retries is a
    /// question asked twice.
    private func providerSettings() -> ProviderSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        if let cachedSettings { return cachedSettings }
        var environment = ProcessInfo.processInfo.environment
        if environment["DUNES_PROVIDER"] == nil {
            environment["DUNES_PROVIDER"] = "openrouter"
            environment["DUNES_MODEL"] = environment["DUNES_MODEL"] ?? "openai/gpt-5.6-luna"
        }
        if environment["DUNES_API_KEY"] == nil,
           let bundled = Bundle.main.object(forInfoDictionaryKey: "DUNESAPIKey") as? String,
           !bundled.isEmpty {
            environment["DUNES_API_KEY"] = bundled
        }
        let settings = ProviderSettings.fromEnvironment(environment, keychain: false)
        if settings.apiKey?.isEmpty != false {
            // The panel says the honest user-facing thing — no model is connected — and
            // that sentence is no use at all to the person who is running this from
            // source and can fix it in ten seconds. This line is for them, on stderr,
            // where a shipped app has no reader and a terminal does.
            let hint = "dunes: no model key. Set DUNES_API_KEY, put it in "
                + "app/.env.local, or add DUNESAPIKey to Info.plist.\n"
            FileHandle.standardError.write(Data(hint.utf8))
        }
        cachedSettings = settings
        return settings
    }

    private func readable(_ kind: String) -> String {
        let words = kind.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
