import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reads photos and screenshots: text via Vision, capture date via EXIF.
public struct ImagePartitioner: Partitioner {
    public init() {}

    public func handles(_ type: UTType) -> Bool { type.conforms(to: .image) }

    public func partition(fileAt url: URL) async throws -> PartitionOutput {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PartitionError.unreadable("This image could not be opened.")
        }

        var elements = try await VisionReader.read(image: image, page: nil)
        var warnings: [String] = []

        if elements.isEmpty {
            // Still a valid document — it just has no text. Keep it listed and findable.
            elements = [DraftElement(.image, url.lastPathComponent)]
            warnings.append("No text was found in this image.")
        }
        return PartitionOutput(elements: elements, pageCount: 1, warnings: warnings)
    }

    /// Capture date from EXIF, for use as the document's own date rather than the ingest time.
    public static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: raw)
    }
}
