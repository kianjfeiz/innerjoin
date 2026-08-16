import CryptoKit
import Foundation
import Network
import os

/// Connecting one mailbox from this machine, with no backend in the middle.
///
/// This is the developer path and the pilot path, not the shipping one. `BackendMailAccess`
/// is how this works for everybody else: the OAuth client secret and the refresh token
/// live on a server, because an app that ships to strangers cannot hold either. Here
/// there are no strangers — it is your Google project, your mailbox, your Mac — so the
/// credentials live in a file beside the library and nothing else has to exist first.
///
/// Google requires the loopback flow for desktop clients: a local listener takes the
/// redirect, so the authorization code never leaves the machine. The out-of-band
/// copy-paste flow that used to serve this purpose was turned off.
public enum GoogleOAuth {

    /// Read-only, and nothing else. It is a restricted scope, which is what makes the
    /// verification conversation with Google unavoidable before this ships — but under
    /// Testing status a project's own test users can grant it today.
    public static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    // MARK: - What gets stored

    /// Everything needed to keep a mailbox connected.
    ///
    /// A file in the workspace at 0600, not the Keychain, and that is a considered
    /// choice for *this* path: a Keychain grant binds to a code identity, and a binary
    /// rebuilt by `swift build` has a new one every time — so the Keychain would ask for
    /// a password on every run and teach whoever is developing to click Deny.
    public struct Credentials: Codable, Equatable, Sendable {
        public var clientID: String
        public var clientSecret: String
        public var refreshToken: String
        public var address: String

        public init(clientID: String, clientSecret: String,
                    refreshToken: String, address: String = "") {
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.refreshToken = refreshToken
            self.address = address
        }

        public static func url(in workspace: URL) -> URL {
            workspace.appendingPathComponent("google.json")
        }

        public static func load(from workspace: URL) -> Credentials? {
            guard let data = try? Data(contentsOf: url(in: workspace)) else { return nil }
            return try? JSONDecoder().decode(Credentials.self, from: data)
        }

        public func save(to workspace: URL) throws {
            let file = Self.url(in: workspace)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: file.path)
        }
    }

    // MARK: - PKCE

    /// A verifier and the challenge derived from it.
    ///
    /// PKCE rather than trusting the client secret, because a desktop client's secret is
    /// in every copy of the binary and Google documents it as non-confidential. The
    /// verifier is generated per attempt and never leaves this process until the code is
    /// exchanged, which is what stops a code intercepted on the loopback from being worth
    /// anything to whoever took it.
    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public var challenge: String {
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return Data(digest).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        public init(verifier: String) { self.verifier = verifier }

        public static func generate() -> PKCE {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            var bytes = [UInt8](repeating: 0, count: 64)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return PKCE(verifier: String(bytes.map { alphabet[Int($0) % alphabet.count] }))
        }
    }

    /// Where to send the browser.
    public static func authorizationURL(clientID: String, redirect: String,
                                        challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Without both of these Google returns an access token and no refresh token,
            // and the connection lasts an hour. `prompt=consent` is the half people
            // forget: after the first grant Google stops issuing refresh tokens unless
            // consent is asked for again.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// Pull `code` and `state` out of whatever the browser asked for.
    public static func code(inRequestLine line: String) -> (code: String, state: String)? {
        guard let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)"),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return nil }
        let state = components.queryItems?.first { $0.name == "state" }?.value ?? ""
        return (code, state)
    }

    // MARK: - Tokens

    public struct Tokens: Sendable, Equatable {
        public let access: String
        public let refresh: String?
        public let expiresIn: Double
    }

    public static func tokens(in reply: [String: Any]) throws -> Tokens {
        if let error = reply["error"] as? String {
            throw HTTPFailure.status(400, "\(error): \(reply["error_description"] as? String ?? "")")
        }
        guard let access = reply["access_token"] as? String else {
            throw HTTPFailure.notJSON("no access_token in \(reply.keys.sorted())")
        }
        return Tokens(access: access,
                      refresh: reply["refresh_token"] as? String,
                      expiresIn: (reply["expires_in"] as? Double) ?? 3600)
    }

    static func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(form($0.value))" }
            .joined(separator: "&").utf8)
        return request
    }

    private static func form(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - The browser round trip

    /// Open the browser, wait for Google to redirect back, and trade the code for tokens.
    ///
    /// Blocks until the person finishes or the timeout runs out, which is right for a
    /// command somebody typed and would be wrong anywhere else.
    public static func connect(clientID: String, clientSecret: String,
                               http: any Fetching = LiveFetching(),
                               open: (URL) -> Void,
                               timeout: TimeInterval = 300) async throws -> Tokens {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let listener = try Loopback()
        let redirect = "http://127.0.0.1:\(listener.port)"

        open(authorizationURL(clientID: clientID, redirect: redirect,
                              challenge: pkce.challenge, state: state))

        let returned = try await listener.waitForCode(timeout: timeout)
        guard returned.state == state else {
            // Not pedantry: without this the listener would accept a code from any tab
            // on the machine that happened to hit the port.
            throw HTTPFailure.status(400, "the reply didn't match the request that started it")
        }

        let reply = try await http.json(tokenRequest([
            "code": returned.code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": pkce.verifier,
        ]))
        let tokens = try tokens(in: reply)
        guard tokens.refresh != nil else {
            throw HTTPFailure.status(400,
                "Google didn't return a refresh token. Remove dunes at "
                + "https://myaccount.google.com/permissions and connect again.")
        }
        return tokens
    }
}

/// A one-shot HTTP listener on localhost, alive only for the length of a sign-in.
final class Loopback: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.start(queue: .global())
        // The port has to be known before the browser is opened, and NWListener assigns
        // it asynchronously.
        var waited = 0
        while listener.port?.rawValue == nil, waited < 200 {
            usleep(10_000)
            waited += 1
        }
        guard let assigned = listener.port?.rawValue else {
            throw HTTPFailure.status(500, "couldn't open a port to receive the sign-in")
        }
        port = assigned
    }

    deinit { listener.cancel() }

    func waitForCode(timeout: TimeInterval) async throws -> (code: String, state: String) {
        // The browser callback and the timeout race each other, and a continuation
        // resumed twice is a crash rather than a bug report. One box, one winner.
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            once.arm(continuation) { [listener] in listener.cancel() }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    let found = GoogleOAuth.code(inRequestLine: request)
                    let body = found == nil
                        ? "That didn't carry a code. Try connecting again."
                        : "dunes is connected. You can close this tab."
                    let response = """
                        HTTP/1.1 200 OK\r
                        Content-Type: text/html; charset=utf-8\r
                        Connection: close\r
                        \r
                        <html><body style="font: 15px -apple-system; padding: 3rem">\
                        <p>\(body)</p></body></html>
                        """
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    if let found { once.finish(.success(found)) }
                }
            }

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                once.finish(.failure(HTTPFailure.status(408, "the sign-in wasn't finished in time")))
            }
        }
    }
}

/// Resume a continuation exactly once, from whichever of several callbacks gets there
/// first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(code: String, state: String), any Error>?
    private var cleanup: (() -> Void)?

    func arm(_ continuation: CheckedContinuation<(code: String, state: String), any Error>,
             cleanup: @escaping () -> Void) {
        lock.lock()
        self.continuation = continuation
        self.cleanup = cleanup
        lock.unlock()
    }

    func finish(_ outcome: Result<(code: String, state: String), any Error>) {
        lock.lock()
        let waiting = continuation
        let done = cleanup
        continuation = nil
        cleanup = nil
        lock.unlock()

        done?()
        waiting?.resume(with: outcome)
    }
}

/// A mailbox connected from this machine.
///
/// Same job as `BackendMailAccess` — hand out short-lived access tokens — with the
/// refresh happening here because there is nowhere else for it to happen yet.
public actor LocalMailAccess: MailAccess {
    private let workspace: URL
    private let http: any Fetching
    private var credentials: GoogleOAuth.Credentials
    private var cached: String?
    private var expires = Date.distantPast

    public init(credentials: GoogleOAuth.Credentials, workspace: URL,
                http: any Fetching = LiveFetching()) {
        self.credentials = credentials
        self.workspace = workspace
        self.http = http
    }

    public func accessToken() async throws -> String {
        if let cached, Date() < expires.addingTimeInterval(-30) { return cached }
        let reply = try await http.json(GoogleOAuth.tokenRequest([
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "refresh_token": credentials.refreshToken,
            "grant_type": "refresh_token",
        ]))
        let tokens = try GoogleOAuth.tokens(in: reply)
        // Google occasionally rotates the refresh token; dropping the new one would work
        // until the old one stopped being accepted, weeks later, for no visible reason.
        if let rotated = tokens.refresh, rotated != credentials.refreshToken {
            credentials.refreshToken = rotated
            try? credentials.save(to: workspace)
        }
        cached = tokens.access
        expires = Date().addingTimeInterval(tokens.expiresIn)
        return tokens.access
    }

    public func invalidate() { cached = nil; expires = .distantPast }
}
