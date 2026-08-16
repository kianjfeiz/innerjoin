import Foundation

/// Getting a Gmail access token, without ever holding the credential that mints one.
///
/// This is the hybrid arrangement, and the split is the point. The backend holds the
/// OAuth client secret and the long-lived refresh token, because a desktop app cannot
/// keep a secret — anything compiled into the binary is readable by anyone who downloads
/// it — and because one place to rotate credentials beats one per installed Mac.
///
/// The mail itself never goes near the backend. The app takes a short-lived access token,
/// calls Gmail directly, and writes what comes back to the user's own disk. So the
/// company holds the keys to the mailbox and never a message from it, and the footer's
/// promise about nothing being uploaded stays true.
public protocol MailAccess: Sendable {
    /// A token good for the next few minutes. Implementations cache; callers may call
    /// this per request without thinking about it.
    func accessToken() async throws -> String
    /// Throw the cached token away. Called once when Gmail says 401 mid-sync, so a token
    /// that expired between two pages doesn't fail the whole run.
    func invalidate() async
}

/// The backend contract, as small as it can be.
///
/// Three endpoints. `link` is called once, with the authorization code the app's existing
/// browser flow already produces — the backend exchanges it, keeps the refresh token, and
/// answers with a first access token. `token` is called from then on. `unlink` forgets.
///
/// The app authenticates to its own backend however the rest of the product does; that
/// bearer is passed in rather than assumed here.
public actor BackendMailAccess: MailAccess {
    private let base: URL
    private let bearer: String
    private let account: String
    private let http: any Fetching

    private var cached: String?
    private var expires = Date.distantPast

    public init(base: URL, bearer: String, account: String, http: any Fetching = LiveFetching()) {
        self.base = base
        self.bearer = bearer
        self.account = account
        self.http = http
    }

    /// Where the backend lives. Environment first for development, then the bundle for a
    /// shipped build — the same order the model credential uses, for the same reason.
    public static func baseURL(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        bundled: String? = Bundle.main.object(forInfoDictionaryKey: "DUNESBackendURL") as? String
    ) -> URL? {
        let written = environment["DUNES_BACKEND_URL"] ?? bundled ?? ""
        return written.isEmpty ? nil : URL(string: written)
    }

    public func accessToken() async throws -> String {
        // Thirty seconds of headroom. A token that is technically still valid when the
        // request is built and expired when it arrives is the kind of failure that only
        // shows up under load, and only sometimes.
        if let cached, Date() < expires.addingTimeInterval(-30) { return cached }
        let reply = try await http.json(post("mail/google/token", ["account": account]))
        return try store(reply)
    }

    public func invalidate() { cached = nil; expires = .distantPast }

    /// One-time: hand over the authorization code and get the mailbox linked.
    @discardableResult
    public func link(code: String, verifier: String, redirect: String) async throws -> String {
        let reply = try await http.json(post("mail/google/link", [
            "account": account,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
        ]))
        _ = try store(reply)
        return reply["email"] as? String ?? ""
    }

    public func unlink() async throws {
        _ = try? await http.json(post("mail/google/unlink", ["account": account]))
        invalidate()
    }

    private func store(_ reply: [String: Any]) throws -> String {
        guard let token = reply["access_token"] as? String, !token.isEmpty else {
            throw HTTPFailure.notJSON("no access_token in the reply")
        }
        cached = token
        expires = Date().addingTimeInterval((reply["expires_in"] as? Double) ?? 300)
        return token
    }

    private func post(_ path: String, _ body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}
