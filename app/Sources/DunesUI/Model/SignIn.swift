import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import DunesCore

/// Getting from a cold launch to a named library.
///
/// Three ways in, and the same destination: an `Account` written beside the library. The
/// two that involve somebody else — Apple, Google — are asked to vouch for a person and
/// nothing more. No token is kept, no file is uploaded, no account is created anywhere.
/// What survives the flow is an identifier, a name, and the fact that the person got
/// through it.
@MainActor
@Observable
final class SignIn: NSObject {

    enum Step: Equatable {
        /// The three doors.
        case welcome
        /// Email, then password. Two fields on one screen ask a person to think about
        /// both at once; one at a time is how every good sign-in reads.
        case email(EmailStage)
        case done
    }

    enum EmailStage: Equatable { case address, password, choosePassword }

    private(set) var step: Step = .welcome
    private(set) var busy = false
    /// What went wrong, in words a person can act on.
    private(set) var problem: String?

    var address = ""
    var password = ""

    private let workspace: URL
    private var existing: Account?
    private var onDone: (Account) -> Void

    init(workspace: URL, onDone: @escaping (Account) -> Void) {
        self.workspace = workspace
        self.existing = AccountStore.load(from: workspace)
        self.onDone = onDone
    }

    /// Put the flow on a given step so a camera can be pointed at it. The steps past
    /// the first door are reached by typing, which a screenshot cannot do.
    func harnessJump(to name: String) {
        switch name {
        case "email":    step = .email(.address)
        case "password": address = "you@example.com"; step = .email(.choosePassword)
        default:         break
        }
    }

    // MARK: - Apple

    func continueWithApple() {
        problem = nil
        busy = true
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    // MARK: - Google

    /// OAuth with PKCE, in the system browser session.
    ///
    /// PKCE rather than a client secret, because a desktop app cannot keep a secret —
    /// anything compiled into it is readable by anyone holding the binary. The code
    /// verifier is generated per attempt and never leaves the process.
    func continueWithGoogle() {
        problem = nil
        guard let clientID = Self.googleClientID else {
            problem = "Google sign-in needs a client ID. Set DUNES_GOOGLE_CLIENT_ID, "
                + "or use Apple or an email address."
            return
        }
        busy = true

        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let redirect = "\(Self.googleRedirectScheme):/oauth"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { busy = false; return }

        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: Self.googleRedirectScheme
        ) { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin { return }
                guard let callback,
                      let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    self.problem = "Google didn't complete the sign-in. Try again."
                    return
                }
                await self.exchange(code: code, verifier: verifier,
                                    clientID: clientID, redirect: redirect)
            }
        }
        session.presentationContextProvider = self
        // The point of signing in is to be remembered; borrowing Safari's session means
        // somebody already signed into Google doesn't type a password again.
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }

    private func exchange(code: String, verifier: String, clientID: String, redirect: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect,
        ]
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.urlEncoded)" }
            .joined(separator: "&").utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Token: Decodable { let id_token: String? }
            guard let idToken = try JSONDecoder().decode(Token.self, from: data).id_token,
                  let claims = Self.claims(fromIDToken: idToken),
                  let subject = claims["sub"] as? String
            else {
                problem = "Google's reply didn't include an identity."
                return
            }
            // The id_token is read for its claims and dropped. Keeping it would mean
            // holding a credential for a service this app never calls again.
            finish(Account(identifier: "google:\(subject)", method: .google,
                           name: claims["name"] as? String,
                           email: claims["email"] as? String,
                           signedInAt: Date()))
        } catch {
            problem = "Couldn't reach Google: \(error.localizedDescription)"
        }
    }

    /// The payload of a JWT, unverified.
    ///
    /// Unverified is correct *here* and nowhere else: the token came back over TLS from
    /// Google's own token endpoint in direct response to a code this process generated,
    /// so it is already as trustworthy as the connection. A signature check would matter
    /// if the token had arrived by any other route.
    private static func claims(fromIDToken token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static var googleClientID: String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment["DUNES_GOOGLE_CLIENT_ID"],
           !fromEnvironment.isEmpty { return fromEnvironment }
        return Bundle.main.object(forInfoDictionaryKey: "DUNESGoogleClientID") as? String
    }

    private static var googleRedirectScheme: String {
        (Bundle.main.bundleIdentifier ?? "com.dunes.app") + ".oauth"
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    // MARK: - Email

    func beginEmail() {
        problem = nil
        address = existing?.email ?? ""
        password = ""
        step = .email(.address)
    }

    /// Whether this address already owns this library decides which question comes next:
    /// "your password" or "choose a password". Asking the wrong one is how sign-up flows
    /// make people feel they've done something wrong.
    func submitAddress() {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@"), trimmed.count > 3 else {
            problem = "That doesn't look like an email address."
            return
        }
        address = trimmed
        problem = nil
        password = ""
        let returning = existing?.method == .email
            && existing?.email?.lowercased() == trimmed.lowercased()
        step = .email(returning ? .password : .choosePassword)
    }

    func submitPassword() {
        guard case .email(let stage) = step else { return }
        problem = nil
        switch stage {
        case .choosePassword:
            guard password.count >= 8 else {
                problem = "Use at least 8 characters."
                return
            }
            finish(Account(identifier: "email:\(address.lowercased())", method: .email,
                           name: nil, email: address, signedInAt: Date(),
                           password: .make(from: password)))
        case .password:
            guard let verifier = existing?.password, verifier.matches(password) else {
                problem = "That password doesn't match."
                password = ""
                return
            }
            var account = existing!
            account.signedInAt = Date()
            finish(account)
        case .address:
            break
        }
    }

    func back() {
        problem = nil
        switch step {
        case .email(.address): step = .welcome
        case .email:           step = .email(.address); password = ""
        default:               step = .welcome
        }
    }

    // MARK: - Finishing

    private func finish(_ account: Account) {
        busy = false
        do {
            try AccountStore.save(account, to: workspace)
        } catch {
            problem = "Couldn't save who you are: \(error.localizedDescription)"
            return
        }
        complete()
    }

    private func complete() {
        guard let account = AccountStore.load(from: workspace) else { return }
        step = .done
        onDone(account)
    }
}

// MARK: - Apple's callbacks

extension SignIn: ASAuthorizationControllerDelegate,
                  ASAuthorizationControllerPresentationContextProviding,
                  ASWebAuthenticationPresentationContextProviding {

    /// Both flows are shown over the panel itself, so the sheet belongs to the window a
    /// person is already looking at rather than arriving from nowhere.
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApplication.shared.windows.first ?? NSWindow() }
    }

    @objc nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApplication.shared.windows.first ?? NSWindow() }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        // Apple gives the name exactly once, on first authorisation. Every later sign-in
        // returns the identifier alone, so what we already know has to be kept.
        let name = credential.fullName.flatMap {
            PersonNameComponentsFormatter().string(from: $0).trimmingCharacters(in: .whitespaces)
        }
        MainActor.assumeIsolated {
            let known = AccountStore.load(from: workspace)
            finish(Account(identifier: "apple:\(credential.user)", method: .apple,
                           name: (name?.isEmpty == false ? name : nil) ?? known?.name,
                           email: credential.email ?? known?.email,
                           signedInAt: Date()))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            busy = false
            let code = (error as? ASAuthorizationError)?.code
            if code == .canceled { return }
            // Sign in with Apple needs a capability that only a signed, entitled build
            // has. Saying so is more use than "an unknown error occurred".
            problem = code == .notInteractive || code == .failed
                ? "Sign in with Apple isn't available in this build. Use Google or an email address."
                : "Apple couldn't complete the sign-in: \(error.localizedDescription)"
        }
    }
}

// MARK: - Small helpers

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
