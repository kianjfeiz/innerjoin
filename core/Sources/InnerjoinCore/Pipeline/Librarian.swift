import Foundation
import GRDB

/// Runs the whole pipeline over a pile of files, and reports as it goes.
///
/// Reading is CPU-bound and parallel; understanding is network-bound and rate-limited.
/// Keeping them in separate lanes means a slow model call never stalls parsing, and a
/// thousand files never open a thousand connections. Each file advances independently,
/// so one bad document can't hold up the rest.
public actor Librarian {
    let store: Store
    let registry: PartitionerRegistry
    let provider: (any ModelProvider)?

    /// Parsing width. One core is left free so the machine stays responsive while a
    /// big folder is being read.
    let readingLanes: Int
    /// Concurrent model calls. Small on purpose: providers rate-limit, and a burst
    /// that trips a limit is slower than a steady trickle.
    let understandingLanes: Int
    /// Whether extraction gets the library's accumulated vocabulary. Off is only for
    /// measuring what that feedback is worth.
    let learningEnabled: Bool

    public init(
        store: Store,
        registry: PartitionerRegistry = .standard,
        provider: (any ModelProvider)? = nil,
        readingLanes: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        understandingLanes: Int = 3,
        learningEnabled: Bool = true
    ) {
        self.learningEnabled = learningEnabled
        self.store = store
        self.registry = registry
        self.provider = provider
        self.readingLanes = readingLanes
        self.understandingLanes = understandingLanes
    }

    public struct Progress: Sendable {
        public var read = 0
        public var understood = 0
        public var alreadyPresent = 0
        public var failed = 0
        public var total = 0
        /// The file being worked on right now, for a status line.
        public var current: String?
    }

    public struct Summary: Sendable {
        public let read: Int
        public let understood: Int
        public let alreadyPresent: Int
        public let failed: Int
        public let problems: [(file: String, reason: String)]
        public let seconds: Double
    }

    /// Reads everything, then understands what was read, then tidies and re-sorts.
    ///
    /// `onProgress` fires on the caller's side as work completes, which is what a
    /// window needs to show a live count rather than freezing until the end.
    @discardableResult
    public func absorb(
        _ inputs: [URL],
        understand: Bool = true,
        settle: Bool = true,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Summary {
        let started = Date()
        let files = expand(inputs)

        var progress = Progress(total: files.count)
        onProgress?(progress)

        var problems: [(String, String)] = []
        var readyToUnderstand: [Int64] = []

        // ---- read, in parallel ----
        let ingest = Ingest(store: store, registry: registry)
        var index = 0
        while index < files.count {
            let batch = Array(files[index..<min(index + readingLanes, files.count)])
            index += batch.count

            let outcomes = await withTaskGroup(of: (URL, Result<Ingest.Result, Error>).self) { group in
                for file in batch {
                    group.addTask {
                        do { return (file, .success(try await ingest.add(fileAt: file))) }
                        catch { return (file, .failure(error)) }
                    }
                }
                var collected: [(URL, Result<Ingest.Result, Error>)] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }

            for (file, outcome) in outcomes {
                progress.current = file.lastPathComponent
                switch outcome {
                case .failure(let error):
                    progress.failed += 1
                    problems.append((file.lastPathComponent, Self.explain(error)))
                case .success(let result):
                    if result.wasAlreadyPresent {
                        progress.alreadyPresent += 1
                    } else if result.document.status == .failed {
                        progress.failed += 1
                        problems.append((result.document.name, result.document.problem ?? "unknown"))
                    } else {
                        progress.read += 1
                        if let id = result.document.id { readyToUnderstand.append(id) }
                    }
                }
                onProgress?(progress)
            }
        }

        // ---- understand, rate-limited ----
        if understand, let provider {
            let distill = Distill(store: store, provider: provider, learningEnabled: learningEnabled)
            var cursor = 0
            while cursor < readyToUnderstand.count {
                let batch = Array(readyToUnderstand[cursor..<min(cursor + understandingLanes,
                                                                readyToUnderstand.count)])
                cursor += batch.count

                let outcomes = await withTaskGroup(of: (Int64, Error?).self) { group in
                    for id in batch {
                        group.addTask {
                            do { _ = try await Self.understandWithRetry(distill, id); return (id, nil) }
                            catch { return (id, error) }
                        }
                    }
                    var collected: [(Int64, Error?)] = []
                    for await outcome in group { collected.append(outcome) }
                    return collected
                }

                for (id, error) in outcomes {
                    let name = (try? store.document(id: id))?.name ?? "\(id)"
                    progress.current = name
                    if let error {
                        // Not fatal: the document keeps its markdown and stays findable.
                        problems.append((name, Self.explain(error)))
                    } else {
                        progress.understood += 1
                    }
                    onProgress?(progress)
                }
            }

            // ---- tidy, sort, settle, sort again ----
            // All of these look at the whole library, so running them per file would
            // be waste. Settling comes after sorting because a document can only be
            // compared with its peers once it has some.
            let tidier = Consolidate(store: store)
            _ = try await tidier.sweepOrphanedLinks()
            _ = try await tidier.run()
            _ = try await Organize(store: store).run()
            if settle {
                // Re-reads only the documents that describe things unlike their peers,
                // which is a small fraction — and the categories can shift once they do.
                _ = try await Refine(store: store, provider: provider).run()
                _ = try await Organize(store: store).run()
            }
            // Names last. Each document was named as it was understood, but merging
            // duplicate entities can change who a document is with, and lanes running
            // in parallel can both reach for the same name. This pass is the one that
            // decides, in document order, so numbering is stable.
            _ = try await Namer(store: store).nameAll()
        }

        return Summary(
            read: progress.read, understood: progress.understood,
            alreadyPresent: progress.alreadyPresent, failed: progress.failed,
            problems: problems, seconds: Date().timeIntervalSince(started)
        )
    }

    /// Understands documents already read but not yet understood — the backfill that
    /// runs when someone connects a model after the fact.
    @discardableResult
    public func understandBacklog(onProgress: (@Sendable (Progress) -> Void)? = nil) async throws -> Summary {
        guard provider != nil else {
            return Summary(read: 0, understood: 0, alreadyPresent: 0, failed: 0,
                           problems: [], seconds: 0)
        }
        let pending = try store.recentDocuments(limit: 10_000)
            .filter { $0.stage == .rendered && $0.status != .failed }
            .compactMap(\.id)
        return try await absorbAlreadyRead(pending, onProgress: onProgress)
    }

    private func absorbAlreadyRead(_ ids: [Int64],
                                   onProgress: (@Sendable (Progress) -> Void)?) async throws -> Summary {
        let started = Date()
        guard let provider else {
            return Summary(read: 0, understood: 0, alreadyPresent: 0, failed: 0, problems: [], seconds: 0)
        }
        let distill = Distill(store: store, provider: provider, learningEnabled: learningEnabled)
        var progress = Progress(total: ids.count)
        var problems: [(String, String)] = []

        var cursor = 0
        while cursor < ids.count {
            let batch = Array(ids[cursor..<min(cursor + understandingLanes, ids.count)])
            cursor += batch.count
            let outcomes = await withTaskGroup(of: (Int64, Error?).self) { group in
                for id in batch {
                    group.addTask {
                        do { _ = try await Self.understandWithRetry(distill, id); return (id, nil) }
                        catch { return (id, error) }
                    }
                }
                var collected: [(Int64, Error?)] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            for (id, error) in outcomes {
                let name = (try? store.document(id: id))?.name ?? "\(id)"
                if let error { problems.append((name, Self.explain(error))) }
                else { progress.understood += 1 }
                onProgress?(progress)
            }
        }
        let tidier = Consolidate(store: store)
        _ = try await tidier.sweepOrphanedLinks()
        _ = try await tidier.run()
        _ = try await Organize(store: store).run()
        _ = try await Namer(store: store).nameAll()

        return Summary(read: 0, understood: progress.understood, alreadyPresent: 0,
                       failed: problems.count, problems: problems,
                       seconds: Date().timeIntervalSince(started))
    }

    /// Three attempts with backoff. Rate limits and blips are the common failure and
    /// they clear on their own; a schema violation won't, so it fails fast.
    private static func understandWithRetry(_ distill: Distill, _ id: Int64) async throws -> Distill.Result {
        var lastError: Error?
        for attempt in 0..<3 {
            do { return try await distill.understand(documentID: id) }
            catch let error as ProviderError {
                lastError = error
                switch error {
                case .malformed, .noContent:
                    // The model answered, just badly. Retrying rarely helps.
                    throw error
                case .noKey:
                    throw error
                case .http(let code, _) where code == 400 || code == 401 || code == 403:
                    throw error
                case .http:
                    try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
                }
            } catch {
                throw error
            }
        }
        throw lastError ?? ProviderError.noContent
    }

    // MARK: - Helpers

    /// Expands folders into the files we can actually read, so counts and progress
    /// reflect real work rather than directory entries.
    private func expand(_ inputs: [URL]) -> [URL] {
        var files: [URL] = []
        for input in inputs {
            let isDirectory = (try? input.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { files.append(input); continue }
            guard let walker = FileManager.default.enumerator(
                at: input, includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    ?? UTType(filenameExtension: url.pathExtension)
                if let type, registry.partitioner(for: type) != nil { files.append(url) }
            }
        }
        return files
    }

    static func explain(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

import UniformTypeIdentifiers
