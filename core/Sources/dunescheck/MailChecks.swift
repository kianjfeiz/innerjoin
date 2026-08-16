import Foundation
import DunesCore

/// Syncing a mailbox.
///
/// All of it runs against a fake Gmail — not to avoid the network, but because the cases
/// worth checking are the ones a real mailbox won't produce on demand: an access token
/// that expires halfway through a backfill, a history cursor Gmail has forgotten, a
/// message that is HTML and nothing else, a thread that appears three times in one page
/// of history. Those are the paths that break in production and never in a demo.
func mailChecks() async {
    print("\nMail · a mailbox, synced and kept up")
    await check("a body is found however deeply the mail nests it", nestedBodies)
    await check("HTML-only mail arrives as readable text", htmlOnly)
    await check("a message becomes a document with its headers on top", messageMarkdown)
    await check("a search pages until it has enough", searchPages)
    await check("history names each message once and moves the cursor", historyAdvances)
    await check("an expired cursor is reported, not thrown", historyExpires)
    await check("a token that expires mid-sync is refreshed once", tokenRefresh)
    await check("the first run backfills and the second costs nothing", twoRuns)
    await check("a forgotten cursor falls back to search without re-reading", restartSkipsKnown)
}

// MARK: - A Gmail that does as it's told

private final class FakeGmail: Fetching, @unchecked Sendable {
    /// path prefix → reply
    var routes: [String: [String: Any]] = [:]
    /// Paths that answer 404 once, then normally.
    var expired: Set<String> = []
    /// How many requests to reject with 401 before answering.
    var unauthorizedFor = 0
    private(set) var paths: [String] = []
    private(set) var tokens: [String] = []

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let url = request.url!
        let path = url.path
        paths.append(url.path + (url.query.map { "?\($0)" } ?? ""))
        tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")

        if unauthorizedFor > 0 {
            unauthorizedFor -= 1
            return (Data(#"{"error":"expired"}"#.utf8), 401)
        }
        if expired.contains(where: { path.hasSuffix($0) }) {
            return (Data(#"{"error":{"code":404}}"#.utf8), 404)
        }
        // Later pages are keyed by the page token so pagination can be scripted.
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "pageToken" }?.value
        let key = token.map { "\(path)#\($0)" } ?? path
        let reply = routes.first { key.hasSuffix($0.key) }?.value ?? [:]
        return (try JSONSerialization.data(withJSONObject: reply), 200)
    }
}

/// A token source that hands out a new token each time it is asked, so a refresh is
/// visible in what the requests carried.
private actor CountingAccess: MailAccess {
    private var issued = 0
    private(set) var refreshes = 0
    private var current: String?

    func accessToken() async throws -> String {
        if let current { return current }
        issued += 1
        current = "token-\(issued)"
        return current!
    }

    func invalidate() { current = nil; refreshes += 1 }
    func refreshCount() -> Int { refreshes }
}

private func gmail(_ fake: FakeGmail, _ access: CountingAccess = CountingAccess()) -> Gmail {
    Gmail(access: access, http: fake)
}

private func encode(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: -

/// Real mail is multipart/mixed wrapping multipart/alternative wrapping the text, with
/// attachments alongside. A scan of the top level finds nothing on most messages.
private func nestedBodies() async throws {
    let payload: [String: Any] = [
        "mimeType": "multipart/mixed",
        "headers": [["name": "Subject", "value": "Lease renewal"],
                    ["name": "From", "value": "dana@example.com"]],
        "parts": [
            ["mimeType": "multipart/alternative", "parts": [
                ["mimeType": "text/html", "body": ["data": encode("<p>ignore me</p>")]],
                ["mimeType": "text/plain", "body": ["data": encode("Rent goes to 2,400.")]],
            ]],
            ["mimeType": "application/pdf", "body": ["attachmentId": "x"]],
        ],
    ]
    let message = Gmail.parse(["payload": payload], id: "m1")
    await expectEqual(message.body, "Rent goes to 2,400.", "the plain part is found two levels down")
    await expectEqual(message.subject, "Lease renewal", "and the headers come with it")
}

private func htmlOnly() async throws {
    let html = "<div>Hi Dana,</div><p>The invoice is <b>&pound;240</b>.</p><br>Thanks"
    let payload: [String: Any] = [
        "mimeType": "text/html", "body": ["data": encode(html)],
        "headers": [["name": "Subject", "value": "Invoice"]],
    ]
    let message = Gmail.parse(["payload": payload], id: "m2")
    await expect(message.body.contains("Hi Dana,"), "the words survive")
    await expect(message.body.contains("240"), "including the ones inside tags")
    await expect(!message.body.contains("<"), "and the markup doesn't")
    // Block tags become line breaks, or marketing mail arrives as one endless paragraph.
    await expect(message.body.contains("\n"), "block tags still break lines")
}

private func messageMarkdown() async throws {
    let message = Gmail.Message(id: "m3", subject: "Rent", from: "dana@example.com",
                                to: "me@example.com", date: "Mon, 1 Jun 2026",
                                body: "Due on the first.")
    let markdown = message.markdown
    await expect(markdown.hasPrefix("# Rent"), "the subject is the heading")
    await expect(markdown.contains("From: dana@example.com"), "who sent it survives")
    // "Who said this and when" is most of what anyone asks about mail, and it is the
    // part extraction can turn into fields.
    await expect(markdown.contains("Date: Mon, 1 Jun 2026"), "and when")
}

private func searchPages() async throws {
    let fake = FakeGmail()
    fake.routes["/messages"] = ["messages": [["id": "a"], ["id": "b"]], "nextPageToken": "p2"]
    fake.routes["/messages#p2"] = ["messages": [["id": "c"]]]

    let ids = try await gmail(fake).search("newer_than:1y", limit: 10)
    await expectEqual(ids, ["a", "b", "c"], "both pages are read")
    await expect(fake.paths.contains { $0.contains("pageToken=p2") }, "using the token it was given")

    let capped = try await gmail(FakeGmail().with { $0.routes["/messages"] =
        ["messages": (1...50).map { ["id": "m\($0)"] }] }).search("q", limit: 5)
    await expectEqual(capped.count, 5, "and the limit is a limit")
}

private func historyAdvances() async throws {
    let fake = FakeGmail()
    // Gmail reports a message once per label change, so a busy thread repeats.
    fake.routes["/history"] = [
        "history": [
            ["messagesAdded": [["message": ["id": "x"]], ["message": ["id": "y"]]]],
            ["messagesAdded": [["message": ["id": "x"]]]],
        ],
        "historyId": 9002,
    ]
    let changes = try await gmail(fake).changes(since: "9000")
    await expectEqual(changes.added, ["x", "y"], "each message once")
    // A number, not a string — Gmail sends it both ways depending on the endpoint.
    await expectEqual(changes.historyID, "9002", "and the cursor moves on")
    await expect(!changes.expired, "nothing expired")
}

/// Gmail keeps history for about a week. A Mac that was off for a fortnight comes back to
/// a cursor that no longer resolves, and that is an ordinary Tuesday, not an error.
private func historyExpires() async throws {
    let fake = FakeGmail()
    fake.expired = ["/history"]
    let changes = try await gmail(fake).changes(since: "1")
    await expect(changes.expired, "an expired cursor is reported as such")
    await expect(changes.added.isEmpty, "with nothing claimed")
}

/// A backfill is many requests over minutes and the token is good for a few. This is the
/// commonest failure in the whole system, and nobody should ever see it.
private func tokenRefresh() async throws {
    let fake = FakeGmail()
    fake.routes["/profile"] = ["emailAddress": "me@example.com", "historyId": "5"]
    fake.unauthorizedFor = 1

    let access = CountingAccess()
    let profile = try await Gmail(access: access, http: fake).profile()
    await expectEqual(profile.address, "me@example.com", "the request succeeds anyway")
    await expectEqual(await access.refreshCount(), 1, "after exactly one refresh")
    await expect(fake.tokens.last != fake.tokens.first, "and the retry carried a new token")
}

private func twoRuns() async throws {
    try await withWorkspace { store, workspace in
        let fake = FakeGmail()
        fake.routes["/profile"] = ["emailAddress": "me@example.com", "historyId": "100"]
        fake.routes["/messages"] = ["messages": [["id": "m1"], ["id": "m2"]]]
        fake.routes["/messages/m1"] = message(subject: "Lease renewal", body: "Rent is 2,400.")
        fake.routes["/messages/m2"] = message(subject: "Gym", body: "Cancelled.")

        let sync = MailSync(store: store, gmail: gmail(fake), workspace: workspace)
        let ingest = Ingest(store: store)

        let first = try await sync.run(ingest: ingest)
        await expectEqual(first.added, 2, "the first run backfills")
        await expectEqual(first.address, "me@example.com", "and knows whose mailbox it is")
        await expect(try store.mailbox("me@example.com")?.historyID == "100",
                     "and writes down where it got to")

        // Nothing new: one history request, no messages fetched, no documents added.
        fake.routes["/history"] = ["historyId": 100]
        let second = try await sync.run(ingest: ingest)
        await expectEqual(second.added, 0, "the second run adds nothing")
        await expect(fake.paths.contains { $0.contains("/history") },
                     "because it asked what changed instead of listing again")
    }
}

/// The fallback has to be cheap, or a week away from the desk turns into re-reading the
/// whole mailbox — and re-extracting it, which is the part that costs money.
private func restartSkipsKnown() async throws {
    try await withWorkspace { store, workspace in
        let fake = FakeGmail()
        fake.routes["/profile"] = ["emailAddress": "me@example.com", "historyId": "200"]
        fake.routes["/messages"] = ["messages": [["id": "m1"], ["id": "m2"]]]
        fake.routes["/messages/m1"] = message(subject: "Lease renewal", body: "Rent is 2,400.")
        fake.routes["/messages/m2"] = message(subject: "Gym", body: "Cancelled.")

        let sync = MailSync(store: store, gmail: gmail(fake), workspace: workspace)
        let ingest = Ingest(store: store)
        _ = try await sync.run(ingest: ingest)

        fake.expired = ["/history"]
        let after = try await sync.run(ingest: ingest)
        await expect(after.restarted, "it says it had to start over")
        await expectEqual(after.added, 0, "but re-reads nothing")
        await expectEqual(after.alreadyHad, 2, "because both were already known")
    }
}

private func message(subject: String, body: String) -> [String: Any] {
    ["payload": [
        "mimeType": "text/plain",
        "headers": [["name": "Subject", "value": subject],
                    ["name": "From", "value": "dana@example.com"],
                    ["name": "Date", "value": "Mon, 1 Jun 2026 09:00:00 +0000"]],
        "body": ["data": encode(body)],
    ]]
}

private extension FakeGmail {
    func with(_ change: (FakeGmail) -> Void) -> FakeGmail { change(self); return self }
}
