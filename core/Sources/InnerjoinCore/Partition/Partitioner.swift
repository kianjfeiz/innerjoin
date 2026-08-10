import Foundation
import UniformTypeIdentifiers

/// What a partitioner produces for one file.
public struct PartitionOutput: Sendable {
    /// Elements in reading order. `tag` and `position` are assigned by the pipeline,
    /// so partitioners leave them at their defaults.
    public var elements: [DraftElement]
    public var pageCount: Int?
    /// Non-fatal problems — "3 of 40 pages had no readable text". Sets status to `.partial`.
    public var warnings: [String]

    public init(elements: [DraftElement], pageCount: Int? = nil, warnings: [String] = []) {
        self.elements = elements
        self.pageCount = pageCount
        self.warnings = warnings
    }
}

/// An element before it has an identity in the database.
public struct DraftElement: Sendable {
    public var kind: ElementKind
    public var text: String
    public var page: Int?
    public var box: BBox?
    public var depth: Int
    public var confidence: Double?

    public init(
        _ kind: ElementKind,
        _ text: String,
        page: Int? = nil,
        box: BBox? = nil,
        depth: Int = 0,
        confidence: Double? = nil
    ) {
        self.kind = kind
        self.text = text
        self.page = page
        self.box = box
        self.depth = depth
        self.confidence = confidence
    }
}

/// Turns one file into elements. One conformer per format family.
///
/// This is the seam that keeps parsing swappable: a hosted service could be dropped
/// in behind this protocol without anything downstream noticing.
public protocol Partitioner: Sendable {
    /// Types this partitioner claims. Checked in registry order, so put specific
    /// partitioners before general ones.
    func handles(_ type: UTType) -> Bool
    func partition(fileAt url: URL) async throws -> PartitionOutput
}

public enum PartitionError: LocalizedError {
    case unreadable(String)
    case passwordProtected
    case unsupported(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why):  return why
        case .passwordProtected:    return "This document is password protected."
        case .unsupported(let t):   return "No reader for \(t) yet."
        case .empty:                return "The file is empty."
        }
    }
}

/// Picks the right partitioner for a type. Order matters — first match wins.
public struct PartitionerRegistry: Sendable {
    private let partitioners: [any Partitioner]

    public init(partitioners: [any Partitioner]) {
        self.partitioners = partitioners
    }

    /// The readers available on-device today. No network, no API key.
    public static let standard = PartitionerRegistry(partitioners: [
        PDFPartitioner(),
        ImagePartitioner(),
        RichTextPartitioner(),
        PlainTextPartitioner(),
    ])

    public func partitioner(for type: UTType) -> (any Partitioner)? {
        partitioners.first { $0.handles(type) }
    }
}
