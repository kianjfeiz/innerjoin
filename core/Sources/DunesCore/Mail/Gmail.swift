import Foundation

/// Gmail, as far as this app is concerned: list what's there, fetch one, and ask what has
/// changed since last time.
///
/// Called directly from the user's own machine with a short-lived token — see
/// `MailAccess` for why the credential that mints those tokens lives somewhere else.
public struct Gmail: Sendable {
    private let access: any MailAccess
    private let http: any Fetching
    private static let root = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

    public init(access: any MailAccess, http: any Fetching = LiveFetching()) {
        self.access = access
        self.http = http
    }

    // MARK: - What the mailbox is

    public struct Profile: Sendable, Equatable {
        public let address: String
        /// Where the mailbox is *now*. Stored after a backfill so the next run can ask
        /// for changes since this point rather than listing everything again.
        public let historyID: String
    }

    public func profile() async throws -> Profile {
        let reply = try await get("profile")
        return Profile(
            address: reply["emailAddress"] as? String ?? "",
            historyID: string(reply["historyId"])
        )
    }

    // MARK: - The two ways to find messages

    /// The first sync: whatever matches the query, newest first, bounded.
    ///
    /// Bounded on purpose. A mailbox is not a folder of documents somebody chose — it is
    /// twenty years of receipts, newsletters and two-line replies, and reading all of it
    /// would cost a fortune in extraction and bury everything the person actually filed.
    public func search(_ query: String, limit: Int) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?

        while ids.count < limit {
            var items = [URLQueryItem(name: "q", value: query),
                         URLQueryItem(name: "maxResults", value: String(min(100, limit - ids.count)))]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }

            let reply = try await get("messages", items)
            let page = (reply["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            ids.append(contentsOf: page)

            guard let next = reply["nextPageToken"] as? String, !page.isEmpty else { break }
            pageToken = next
        }
        return Array(ids.prefix(limit))
    }

    /// Every sync after the first: what has arrived since a known point.
    ///
    /// This is the whole of "persistent" — the stored `historyId` is a cursor, so a sync
    /// costs one request plus the new messages rather than a walk of the mailbox. Gmail
    /// expires history after about a week, and says so with a 404; the caller's job is
    /// then to fall back to a search, which is why that case is named rather than thrown
    /// as a generic failure.
    public struct Changes: Sendable, Equatable {
        public let added: [String]
        public let historyID: String
        /// True when Gmail has forgotten the cursor and a backfill is the only way back.
        public let expired: Bool
    }

    public func changes(since cursor: String) async throws -> Changes {
        var added: [String] = []
        var latest = cursor
        var pageToken: String?

        repeat {
            var items = [URLQueryItem(name: "startHistoryId", value: cursor),
                         URLQueryItem(name: "historyTypes", value: "messageAdded")]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }

            let reply: [String: Any]
            do {
                reply = try await get("history", items)
            } catch HTTPFailure.status(404, _) {
                return Changes(added: [], historyID: cursor, expired: true)
            }

            for entry in reply["history"] as? [[String: Any]] ?? [] {
                for wrapper in entry["messagesAdded"] as? [[String: Any]] ?? [] {
                    if let message = wrapper["message"] as? [String: Any],
                       let id = message["id"] as? String { added.append(id) }
                }
            }
            latest = string(reply["historyId"], fallback: latest)
            pageToken = reply["nextPageToken"] as? String
        } while pageToken != nil

        // Gmail reports the same message once per label change, so a busy thread can
        // arrive several times in one page of history.
        var seen = Set<String>()
        return Changes(added: added.filter { seen.insert($0).inserted },
                       historyID: latest, expired: false)
    }

    // MARK: - One message

    public struct Message: Sendable, Equatable {
        public let id: String
        public let subject: String
        public let from: String
        public let to: String
        public let date: String
        public let body: String

        public init(id: String, subject: String, from: String, to: String,
                    date: String, body: String) {
            self.id = id
            self.subject = subject
            self.from = from
            self.to = to
            self.date = date
            self.body = body
        }

        /// What gets written to disk and read by the ordinary pipeline.
        ///
        /// Headers first as a small block, then the body. The header block is what makes
        /// an email answerable at all — "who said this and when" is most of what anyone
        /// asks about mail, and it is the part that survives extraction as fields.
        public var markdown: String {
            var out = "# \(subject.isEmpty ? "(no subject)" : subject)\n\n"
            if !from.isEmpty { out += "From: \(from)\n" }
            if !to.isEmpty   { out += "To: \(to)\n" }
            if !date.isEmpty { out += "Date: \(date)\n" }
            out += "\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            return out
        }
    }

    public func message(_ id: String) async throws -> Message {
        let reply = try await get("messages/\(id)", [URLQueryItem(name: "format", value: "full")])
        return Gmail.parse(reply, id: id)
    }

    /// Turn Gmail's payload tree into a message. Pure, so the shapes that actually cause
    /// trouble — nested multiparts, HTML-only mail, missing headers — are checkable.
    public static func parse(_ reply: [String: Any], id: String) -> Message {
        let payload = reply["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []

        func header(_ name: String) -> String {
            headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }
                .flatMap { $0["value"] as? String } ?? ""
        }

        let plain = body(in: payload, matching: "text/plain")
        let body = plain.isEmpty ? stripHTML(Gmail.body(in: payload, matching: "text/html")) : plain

        return Message(
            id: id,
            subject: header("Subject"),
            from: header("From"),
            to: header("To"),
            date: header("Date"),
            body: body.isEmpty ? (reply["snippet"] as? String ?? "") : body
        )
    }

    /// Walk the parts depth-first for the first body of this type.
    ///
    /// Real mail nests: multipart/mixed holding a multipart/alternative holding the two
    /// versions of the text, with attachments beside them. A flat scan of the top level
    /// finds nothing at all on most messages anyone actually receives.
    private static func body(in part: [String: Any], matching type: String) -> String {
        if (part["mimeType"] as? String) == type,
           let data = (part["body"] as? [String: Any])?["data"] as? String,
           let decoded = decode(data) {
            return decoded
        }
        for child in part["parts"] as? [[String: Any]] ?? [] {
            let found = body(in: child, matching: type)
            if !found.isEmpty { return found }
        }
        return ""
    }

    /// Base64url, which is base64 with two characters swapped and the padding left off.
    static func decode(_ text: String) -> String? {
        var padded = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded, options: [.ignoreUnknownCharacters])
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Enough HTML removal to leave readable text.
    ///
    /// Not a parser. Marketing mail is mostly table markup, and what matters is that the
    /// words survive and the tags don't — a real HTML parse would be a dependency for a
    /// job whose failure mode is a stray angle bracket.
    static func stripHTML(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var out = ""
        var depth = 0
        var tag = ""
        for character in html {
            if character == "<" { depth += 1; tag = ""; continue }
            if character == ">" {
                depth = max(0, depth - 1)
                // Block-level tags are where lines break; without this everything
                // arrives as one paragraph a thousand words long.
                let name = tag.lowercased().trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("/p") || name.hasPrefix("br") || name.hasPrefix("/div")
                    || name.hasPrefix("/tr") || name.hasPrefix("/h") { out += "\n" }
                continue
            }
            if depth > 0 { tag.append(character) } else { out.append(character) }
        }
        return out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - Requests

    /// One retry on 401, and only on 401.
    ///
    /// A sync is many requests over minutes, and an access token good for five of them
    /// will expire in the middle of a backfill. Refreshing and retrying once turns the
    /// commonest failure in the whole system into something nobody sees.
    private func get(_ path: String, _ items: [URLQueryItem] = []) async throws -> [String: Any] {
        do {
            return try await http.json(request(path, items, token: try await access.accessToken()))
        } catch let error where http.isUnauthorized(error) {
            await access.invalidate()
            return try await http.json(request(path, items, token: try await access.accessToken()))
        }
    }

    private func request(_ path: String, _ items: [URLQueryItem], token: String) -> URLRequest {
        var components = URLComponents(url: Gmail.root.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !items.isEmpty { components.queryItems = items }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Gmail sends historyId as a number in some replies and a string in others.
    private func string(_ value: Any?, fallback: String = "") -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return fallback
    }
}
