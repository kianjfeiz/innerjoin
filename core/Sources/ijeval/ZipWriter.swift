import Foundation

/// Writes stored (uncompressed) ZIP archives, which is all the evaluation corpus needs
/// to produce real Office documents. Deflate would only save disk on throwaway files.
struct ZipWriter {
    private struct Entry {
        let name: String
        let crc: UInt32
        let size: Int
        let offset: Int
    }

    private var buffer = Data()
    private var entries: [Entry] = []

    mutating func add(_ name: String, _ contents: String) {
        let payload = Data(contents.utf8)
        let offset = buffer.count
        let crc = ZipWriter.crc32(payload)

        buffer.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])   // local header
        buffer.append(contentsOf: uint16(20)); buffer.append(contentsOf: uint16(0))   // version, flags
        buffer.append(contentsOf: uint16(0))                              // method: stored
        buffer.append(contentsOf: uint16(0)); buffer.append(contentsOf: uint16(0))    // time, date
        buffer.append(contentsOf: uint32(crc))
        buffer.append(contentsOf: uint32(UInt32(payload.count)))          // compressed
        buffer.append(contentsOf: uint32(UInt32(payload.count)))          // uncompressed
        buffer.append(contentsOf: uint16(UInt16(name.utf8.count)))
        buffer.append(contentsOf: uint16(0))                              // extra length
        buffer.append(contentsOf: Array(name.utf8))
        buffer.append(payload)

        entries.append(Entry(name: name, crc: crc, size: payload.count, offset: offset))
    }

    func write(to url: URL) throws {
        var output = buffer
        let directoryStart = output.count

        for entry in entries {
            output.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])   // central directory
            output.append(contentsOf: uint16(20)); output.append(contentsOf: uint16(20))
            output.append(contentsOf: uint16(0)); output.append(contentsOf: uint16(0))
            output.append(contentsOf: uint16(0)); output.append(contentsOf: uint16(0))
            output.append(contentsOf: uint32(entry.crc))
            output.append(contentsOf: uint32(UInt32(entry.size)))
            output.append(contentsOf: uint32(UInt32(entry.size)))
            output.append(contentsOf: uint16(UInt16(entry.name.utf8.count)))
            output.append(contentsOf: uint16(0)); output.append(contentsOf: uint16(0))     // extra, comment
            output.append(contentsOf: uint16(0)); output.append(contentsOf: uint16(0))     // disk, internal attrs
            output.append(contentsOf: uint32(0))                               // external attrs
            output.append(contentsOf: uint32(UInt32(entry.offset)))
            output.append(contentsOf: Array(entry.name.utf8))
        }

        output.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])        // end of directory
        output.append(contentsOf: uint16(0)); output.append(contentsOf: uint16(0))
        output.append(contentsOf: uint16(UInt16(entries.count)))
        output.append(contentsOf: uint16(UInt16(entries.count)))
        output.append(contentsOf: uint32(UInt32(output.count - directoryStart)))
        output.append(contentsOf: uint32(UInt32(directoryStart)))
        output.append(contentsOf: uint16(0))                                   // comment length
        try output.write(to: url)
    }

    private func uint16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }
    private func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
         UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1) }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
