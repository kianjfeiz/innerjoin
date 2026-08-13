import Foundation
import GRDB
import UniformTypeIdentifiers

/// Runs a file through the on-device stages: into the vault, parsed into elements,
/// rendered to markdown. No network, no API key, nothing leaves the Mac.
public struct Ingest: Sendable {
    let store: Store
    let registry: PartitionerRegistry

    public init(store: Store, registry: PartitionerRegistry = .standard) {
        self.store = store
        self.registry = registry
    }

    public struct Result: Sendable {
        public let document: Document
        public let elementCount: Int
        /// True when this file was already in the library — nothing was re-done.
        public let wasAlreadyPresent: Bool
    }

    /// Adds one file. Safe to call repeatedly: identical bytes are recognized and skipped.
    @discardableResult
    public func add(fileAt source: URL) async throws -> Result {
        // ---- Stage 0 · take it in -------------------------------------------------
        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }

        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteSize > 0 else { throw PartitionError.empty }

        let hash = try Vault.hash(contentsOf: source)
        if let existing = try store.document(sha256: hash) {
            return Result(document: existing,
                          elementCount: try store.elements(of: existing.id!).count,
                          wasAlreadyPresent: true)
        }

        let type = resolveType(of: source)
        let name = source.lastPathComponent
        let vaultPath = try store.vault.store(source, sha256: hash, name: name)

        let draft = Document(
            vaultPath: vaultPath,
            name: name,
            sha256: hash,
            typeIdentifier: type.identifier,
            byteSize: byteSize,
            createdAt: ImagePartitioner.captureDate(of: source)
                ?? attributes[.creationDate] as? Date,
            stage: .added
        )
        var document = try await store.dbQueue.write { db -> Document in
            var inserting = draft
            try inserting.insert(db)
            return inserting
        }
        let documentID = document.id!

        // ---- Stage 1 · read it ----------------------------------------------------
        guard let partitioner = registry.partitioner(for: type) else {
            let reason = "No reader for \(type.localizedDescription ?? type.identifier) yet."
            return Result(document: try await markFailed(document, reason),
                          elementCount: 0, wasAlreadyPresent: false)
        }

        let output: PartitionOutput
        do {
            output = try await partitioner.partition(fileAt: store.vault.url(for: vaultPath))
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return Result(document: try await markFailed(document, reason),
                          elementCount: 0, wasAlreadyPresent: false)
        }

        // Repairs that apply whatever read the file: ligatures back to letters, and
        // flattened bullet lists back into list items.
        let cleaned = Tidying.clean(output.elements)
        let elements = cleaned.enumerated().map { position, draft in
            Element(documentID: documentID,
                    position: position,
                    tag: Element.tag(for: position),
                    kind: draft.kind,
                    text: draft.text,
                    page: draft.page,
                    box: draft.box,
                    depth: draft.depth,
                    confidence: draft.confidence)
        }

        // ---- Stage 2 · render it --------------------------------------------------
        let markdown = Rendition.render(elements)

        document.pageCount = output.pageCount
        document.markdown = markdown
        document.stage = .rendered
        document.status = output.warnings.isEmpty ? .ok : .partial
        document.problem = output.warnings.isEmpty ? nil : output.warnings.joined(separator: " ")

        // One transaction: either the document is fully parsed or it isn't.
        let finished = document
        try await store.dbQueue.write { db in
            for var element in elements { try element.insert(db) }
            try finished.update(db)
        }

        return Result(document: finished, elementCount: elements.count, wasAlreadyPresent: false)
    }

    /// Adds every readable file under a folder. Failures are recorded, never fatal —
    /// one bad file must not stop a thousand good ones.
    public func addContents(of folder: URL, recursive: Bool = true) async throws -> [Result] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        // Collect first: directory enumeration is synchronous, the reading that follows isn't.
        let candidates = walker.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                && registry.partitioner(for: resolveType(of: url)) != nil
        }

        var results: [Result] = []
        for url in candidates {
            if let result = try? await add(fileAt: url) { results.append(result) }
        }
        return results
    }

    // MARK: - Helpers

    /// Extensions lie, so fall back to content sniffing when the extension is unknown.
    private func resolveType(of url: URL) -> UTType {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type }
        if let type = UTType(filenameExtension: url.pathExtension) { return type }
        return .data
    }

    /// A file we couldn't read still keeps its row — it stays visible and listed
    /// with a plain-language reason, rather than vanishing.
    private func markFailed(_ document: Document, _ reason: String) async throws -> Document {
        var failed = document
        failed.status = .failed
        failed.problem = reason
        let final = failed
        try await store.dbQueue.write { db in try final.update(db) }
        return final
    }
}
