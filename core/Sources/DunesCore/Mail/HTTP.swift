import Foundation

/// The one seam that makes everything above it checkable.
///
/// Gmail and the backend are both "send a request, get JSON back", and neither is
/// something a check should reach. Everything that talks to a network goes through this,
/// so the checks hand over canned replies and exercise the real parsing, the real
/// pagination, the real retry — rather than proving that a mock returns what it was told
/// to return.
public protocol Fetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, Int)
}

public struct LiveFetching: Fetching {
    public init() {}

    public func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum HTTPFailure: Error, CustomStringConvertible {
    case status(Int, String)
    case notJSON(String)
    case noBackend

    public var description: String {
        switch self {
        case .status(let code, let body):
            "the server answered \(code): \(body.prefix(200))"
        case .notJSON(let body):
            "expected JSON, got: \(body.prefix(120))"
        case .noBackend:
            "no backend configured — set DUNES_BACKEND_URL or DUNESBackendURL in Info.plist"
        }
    }
}

extension Fetching {
    /// A request that must come back as a JSON object.
    ///
    /// 401 is separated out because it is the one status with a cure: an access token
    /// that has expired mid-sync should be refreshed and the request retried once, not
    /// reported to somebody as a failure.
    func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, status) = try await fetch(request)
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else { throw HTTPFailure.status(status, body) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPFailure.notJSON(body)
        }
        return object
    }

    func isUnauthorized(_ error: any Error) -> Bool {
        if case HTTPFailure.status(401, _) = error { return true }
        return false
    }
}
