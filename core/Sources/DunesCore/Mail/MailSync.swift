import Foundation

/// One run of "go and get the mail".
///
/// The whole shape is two paths and a cursor. With no cursor it backfills — a bounded
/// search, newest first. With one it asks Gmail what has changed since, which costs a
/// single request when nothing has. Either way the messages are written to disk and read
/// by the ordinary pipeline, so mail becomes documents like everything else: extracted,
/// anchored, citable, and countable in the same library.
///
/// Safe to run on a timer, which is the point of it. Nothing here assumes it is the first
/// run, the tenth, or one that follows a week of the Mac being off.
public struct MailSync: Sendable {
    let store: Store
    let gmail: Gmail
    let workspace: URL

    public init(store: Store, gmail: Gmail, workspace: URL) {
        self.store = store
        self.gmail = gmail
        self.workspace = workspace
    }

    public struct Report: Sendable, Equatable {
        public var address = ""
        public var added = 0
        public var alreadyHad = 0
        public var failed = 0
        /// True when Gmail had forgotten the cursor and this run had to backfill instead.
        public var restarted = false

        public var summary: String {
            var line = "\(added) new, \(alreadyHad) already there"
            if failed > 0 { line += ", \(failed) couldn't be read" }
            if restarted { line += " (history had expired, so it searched instead)" }
            return line
        }
    }

    /// The default backfill window.
    ///
    /// A mailbox is not a folder somebody curated — it's twenty years of receipts and
    /// newsletters, and reading all of it would cost a fortune in extraction and bury the
    /// documents the person actually chose to keep. Newer, and excluding the categories
    /// Gmail itself files as noise, is a better library than "everything".
    public static let defaultQuery = "newer_than:1y -category:promotions -category:social"

    public func run(query: String = MailSync.defaultQuery,
                    limit: Int = 200,
                    ingest: Ingest) async throws -> Report {
        var report = Report()
        let profile = try await gmail.profile()
        report.address = profile.address

        let known = try store.mailbox(profile.address)
        var ids: [String]
        var cursor = profile.historyID

        if let known {
            let changes = try await gmail.changes(since: known.historyID)
            if changes.expired {
                // Gmail keeps history for about a week. A Mac that was off for a
                // fortnight comes back to a cursor that no longer resolves, and the only
                // way home is to search again — the message table makes that cheap,
                // because everything already read is skipped without being fetched.
                report.restarted = true
                ids = try await gmail.search(query, limit: limit)
            } else {
                ids = changes.added
                cursor = changes.historyID
            }
        } else {
            ids = try await gmail.search(query, limit: limit)
        }

        let seen = try store.knownMailMessages(ids)
        report.alreadyHad = ids.filter { seen.contains($0) }.count

        for id in ids where !seen.contains(id) {
            do {
                let message = try await gmail.message(id)
                let url = try write(message, for: profile.address)
                let outcome = try await ingest.add(fileAt: url)
                try store.rememberMailMessage(MailMessage(
                    id: id, address: profile.address, documentID: outcome.document.id))
                report.added += 1
            } catch {
                // One unreadable message must not end a sync. It is recorded as a
                // failure and the cursor still advances, or a single malformed mail
                // would block every message behind it forever.
                report.failed += 1
            }
        }

        try store.rememberMailbox(Mailbox(address: profile.address, historyID: cursor))
        return report
    }

    /// Written to the workspace, beside the library it feeds, one folder per address.
    ///
    /// The Gmail id goes in the filename because subjects collide constantly — "Re: hi"
    /// is not a unique document — and because it makes the file the message came from
    /// findable from the row in the database.
    private func write(_ message: Gmail.Message, for address: String) throws -> URL {
        let folder = workspace.appendingPathComponent("mail").appendingPathComponent(address)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let subject = message.subject.isEmpty ? "(no subject)" : message.subject
        let safe = subject
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let short = safe.count > 60 ? String(safe.prefix(60)).trimmingCharacters(in: .whitespaces) : safe

        let url = folder.appendingPathComponent("\(short.isEmpty ? "message" : short) [\(message.id)].md")
        try Data(message.markdown.utf8).write(to: url, options: .atomic)
        return url
    }
}
