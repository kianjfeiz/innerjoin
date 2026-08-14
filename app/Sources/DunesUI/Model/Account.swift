import Foundation
import CryptoKit

/// Who this library belongs to.
///
/// Signing in names an owner. It does not move anything: the documents, the records and
/// the answers stay in the workspace folder on this Mac, exactly as the panel's footer
/// promises. Apple and Google are asked to *vouch for a person*, never to hold a file —
/// which is why what's kept here is an identifier and a display name, and nothing else.
///
/// Stored beside the library rather than in the keychain, deliberately. A keychain read
/// costs a permission dialog per process, and an app that asked for a password to find
/// out who was already signed in would be charging the user for its own bookkeeping.
/// The one genuine secret — the model API key — stays in the keychain where it belongs.
struct Account: Codable, Equatable, Sendable {

    enum Method: String, Codable, Sendable {
        case apple, google, email

        var label: String {
            switch self {
            case .apple:  return "Apple"
            case .google: return "Google"
            case .email:  return "email"
            }
        }
    }

    /// Stable for the life of the account: Apple and Google both hand back a subject
    /// identifier that outlives a changed display name or a changed address.
    var identifier: String
    var method: Method
    var name: String?
    var email: String?
    var signedInAt: Date

    /// What to call them. Falls back through what each method actually gives us —
    /// Apple hands over a name once, at first authorisation, and never again.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, let handle = email.split(separator: "@").first { return String(handle) }
        return "you"
    }

    /// Only set for an email account: the salt and verifier for the password. A password
    /// is never stored, here or anywhere else — this is what it derives to.
    var password: PasswordVerifier?

    // MARK: - Passwords

    /// PBKDF2-HMAC-SHA256, salted per account.
    ///
    /// There is no server to authenticate against, so this guards one thing: somebody
    /// with the disk should not learn a password that is probably reused elsewhere.
    /// That makes the cost factor the whole point — a fast hash would leave the file as
    /// good as plaintext against anyone willing to spend an afternoon on it.
    struct PasswordVerifier: Codable, Equatable, Sendable {
        var salt: Data
        var hash: Data
        var rounds: Int

        static let defaultRounds = 210_000

        static func make(from password: String, rounds: Int = defaultRounds) -> PasswordVerifier {
            var salt = Data(count: 16)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            return PasswordVerifier(salt: salt,
                                    hash: derive(password: password, salt: salt, rounds: rounds),
                                    rounds: rounds)
        }

        func matches(_ password: String) -> Bool {
            let candidate = Self.derive(password: password, salt: salt, rounds: rounds)
            // Constant time: a comparison that returns early leaks how much of the hash
            // was right, one byte at a time.
            guard candidate.count == hash.count else { return false }
            var difference: UInt8 = 0
            for (a, b) in zip(candidate, hash) { difference |= a ^ b }
            return difference == 0
        }

        /// PBKDF2 written on CryptoKit's HMAC, because CryptoKit has no PBKDF2 of its
        /// own and CommonCrypto's is a C API that wants pointers into Swift strings.
        private static func derive(password: String, salt: Data, rounds: Int) -> Data {
            let key = SymmetricKey(data: Data(password.utf8))
            var block = Data(salt)
            block.append(contentsOf: [0, 0, 0, 1])          // PBKDF2 block index
            var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
            var result = u
            for _ in 1..<rounds {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for index in result.indices { result[index] ^= u[index] }
            }
            return result
        }
    }
}

// MARK: - Where it lives

/// Reading and writing the account file, and nothing else.
enum AccountStore {

    static func url(in workspace: URL) -> URL {
        workspace.appendingPathComponent("account.json")
    }

    static func load(from workspace: URL) -> Account? {
        guard let data = try? Data(contentsOf: url(in: workspace)) else { return nil }
        return try? JSONDecoder.dunes.decode(Account.self, from: data)
    }

    static func save(_ account: Account, to workspace: URL) throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let data = try JSONEncoder.dunes.encode(account)
        try data.write(to: url(in: workspace), options: .atomic)
        // The file names a person and holds a password verifier. Nobody else on the
        // machine has any business reading it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url(in: workspace).path)
    }

    static func clear(from workspace: URL) {
        try? FileManager.default.removeItem(at: url(in: workspace))
    }
}

extension JSONEncoder {
    static var dunes: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var dunes: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
