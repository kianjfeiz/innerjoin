import Foundation
import Compression

/// Just enough ZIP to read Office documents.
///
/// A full archive library would be another dependency to ship, update, and audit for
/// a format we only ever read — and only ever the handful of XML parts inside. This
/// walks the central directory and inflates with the system Compression framework.
struct Zip {
    private let data: Data
    private let entries: [String: Entry]

    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    var entryNames: [String] { Array(entries.keys) }

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url), data.count > 22 else {
            throw PartitionError.unreadable("This file could not be opened.")
        }
        self.data = data
        self.entries = try Zip.readCentralDirectory(data)
        guard !entries.isEmpty else { throw PartitionError.unreadable("The archive is empty.") }
    }

    /// Reads one entry as UTF-8 text. Returns nil when the entry isn't present, which
    /// is normal — not every workbook has shared strings.
    func text(of name: String) throws -> String? {
        guard let entry = entries[name] else { return nil }
        guard let bytes = try extract(entry) else { return nil }
        return String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .isoLatin1)
    }

    private func extract(_ entry: Entry) throws -> Data? {
        // The local header repeats the name and extra field, and their lengths differ
        // from the central directory's, so the data offset has to be read from here.
        let headerStart = entry.localHeaderOffset
        guard headerStart + 30 <= data.count,
              Zip.readUInt32(data, headerStart) == 0x0403_4b50 else { return nil }

        let nameLength = Int(Zip.readUInt16(data, headerStart + 26))
        let extraLength = Int(Zip.readUInt16(data, headerStart + 28))
        let start = headerStart + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { return nil }

        let payload = data.subdata(in: start..<end)
        switch entry.compressionMethod {
        case 0:  return payload                          // stored
        case 8:  return Zip.inflate(payload, expecting: entry.uncompressedSize)
        default: return nil                              // nothing else appears in Office files
        }
    }

    /// Raw deflate — `COMPRESSION_ZLIB` in Apple's framework means the bare stream,
    /// without the zlib header ZIP omits.
    static func inflate(_ payload: Data, expecting size: Int) -> Data? {
        guard size > 0 else { return Data() }
        // A corrupt size field shouldn't be able to ask for gigabytes.
        let capacity = min(max(size, 1), 256 << 20)
        var output = Data(count: capacity)

        let written = output.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, capacity,
                                                 sourceBase, payload.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // MARK: - Directory

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        guard let eocd = findEndOfCentralDirectory(data) else {
            throw PartitionError.unreadable("This doesn't look like a valid archive.")
        }
        let count = Int(readUInt16(data, eocd + 10))
        var offset = Int(readUInt32(data, eocd + 16))

        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, readUInt32(data, offset) == 0x0201_4b50 else { break }
            let method = readUInt16(data, offset + 10)
            let compressed = Int(readUInt32(data, offset + 20))
            let uncompressed = Int(readUInt32(data, offset + 24))
            let nameLength = Int(readUInt16(data, offset + 28))
            let extraLength = Int(readUInt16(data, offset + 30))
            let commentLength = Int(readUInt16(data, offset + 32))
            let localOffset = Int(readUInt32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)),
                              encoding: .utf8) ?? ""
            if !name.isEmpty, !name.hasSuffix("/") {
                entries[name] = Entry(name: name, compressionMethod: method,
                                      compressedSize: compressed, uncompressedSize: uncompressed,
                                      localHeaderOffset: localOffset)
            }
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// The end-of-central-directory record sits at the tail, after a comment of
    /// unknown length, so it has to be searched for backwards.
    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let earliest = max(0, data.count - minimum - 65_535)
        var index = data.count - minimum
        while index >= earliest {
            if readUInt32(data, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    // ZIP is little-endian throughout.
    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset])
            | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[data.startIndex + offset])
            | UInt32(data[data.startIndex + offset + 1]) << 8
            | UInt32(data[data.startIndex + offset + 2]) << 16
            | UInt32(data[data.startIndex + offset + 3]) << 24
    }
}
