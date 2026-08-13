import Foundation
import CryptoKit

/// Holds copies of the originals. The user's own files are never moved or modified.
///
/// Files are stored under `files/<first-2-of-hash>/<hash>/<original name>` — the hash
/// prefix keeps directories small, and keeping the real filename means the vault is
/// legible to a human browsing it in Finder.
public struct Vault: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Streams the file to compute SHA-256 without loading it into memory.
    public static func hash(contentsOf url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func relativePath(sha256: String, name: String) -> String {
        "\(sha256.prefix(2))/\(sha256)/\(name)"
    }

    public func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Copies a file in. Returns the vault-relative path. Idempotent: if the same
    /// bytes are already stored, the existing copy is kept.
    @discardableResult
    public func store(_ source: URL, sha256: String, name: String) throws -> String {
        let relative = relativePath(sha256: sha256, name: name)
        let destination = url(for: relative)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return relative }
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        return relative
    }
}
