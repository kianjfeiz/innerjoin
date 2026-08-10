import Foundation
import UniformTypeIdentifiers

/// Reads `.eml` and Apple Mail's `.emlx`.
///
/// Email is where amendments live — the message that changes what a contract said —
/// so the headers matter as much as the body. Subject becomes the title, and
/// From/To/Date become their own elements so a model can cite "who said this, when"
/// the way it would cite a page.
public struct EmailPartitioner: Partitioner {
    public init() {}

    public func handles(_ type: UTType) -> Bool {
        if let email = UTType("com.apple.mail.email"), type.conforms(to: email) { return true }
        if let emlx = UTType("com.apple.mail.emlx"), type.conforms(to: emlx) { return true }
        return type.identifier == "public.eml" || type.preferredFilenameExtension == "eml"
    }

    public func partition(fileAt url: URL) async throws -> PartitionOutput {
        guard let data = try? Data(contentsOf: url) else {
            throw PartitionError.unreadable("This message could not be opened.")
        }
        // .emlx is an RFC 822 message with a byte-count first line and a plist trailer.
        let raw = Self.decodeText(data)
        let message = url.pathExtension.lowercased() == "emlx" ? Self.stripEmlxWrapper(raw) : raw

        let (headers, body) = Self.splitHeaders(message)
        guard !headers.isEmpty || !body.trimmed.isEmpty else { throw PartitionError.empty }

        var elements: [DraftElement] = []
        let subject = headers["subject"]?.trimmed
        elements.append(DraftElement(.title, subject?.nilIfEmpty ?? url.deletingPathExtension().lastPathComponent))

        // Header lines carry the facts a model needs to place the message in time.
        for key in ["from", "to", "cc", "date"] {
            guard let value = headers[key]?.trimmed, !value.isEmpty else { continue }
            elements.append(DraftElement(.text, "\(key.capitalizedFirst): \(value)"))
        }

        let text = Self.decodeBody(body, headers: headers)
        for block in text.components(separatedBy: "\n\n") {
            let trimmed = Self.stripQuotedReply(block).trimmed
            guard !trimmed.isEmpty else { continue }
            elements.append(DraftElement(.text, trimmed))
        }

        var warnings: [String] = []
        if let attachments = Self.attachmentNames(message), !attachments.isEmpty {
            // Named, not parsed: an attachment is its own document and should be added
            // as one rather than smuggled into this message's text.
            warnings.append("Attachments not read: \(attachments.joined(separator: ", ")).")
        }
        guard elements.count > 1 else { throw PartitionError.empty }
        return PartitionOutput(elements: elements, pageCount: nil, warnings: warnings)
    }

    // MARK: - Parsing

    static func decodeText(_ data: Data) -> String {
        for encoding: String.Encoding in [.utf8, .isoLatin1, .windowsCP1252, .ascii] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return ""
    }

    /// `.emlx` prefixes the message with a byte count and appends a plist.
    static func stripEmlxWrapper(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, Int(first.trimmed) != nil { lines.removeFirst() }
        if let plist = lines.firstIndex(where: { $0.hasPrefix("<?xml") }) {
            lines = Array(lines[..<plist])
        }
        return lines.joined(separator: "\n")
    }

    /// Splits headers from body, unfolding the continuation lines that long headers use.
    static func splitHeaders(_ message: String) -> (headers: [String: String], body: String) {
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        guard let head = parts.first else { return ([:], normalized) }
        let body = parts.dropFirst().joined(separator: "\n\n")

        var headers: [String: String] = [:]
        var currentKey: String?
        for line in head.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let key = currentKey { headers[key, default: ""] += " " + line.trimmed }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased().trimmed
            let value = String(line[line.index(after: colon)...]).trimmed
            headers[key] = value
            currentKey = key
        }
        return (headers.mapValues { decodeEncodedWords($0) }, body)
    }

    /// Picks the readable part of a multipart message, preferring plain text over HTML.
    static func decodeBody(_ body: String, headers: [String: String]) -> String {
        let contentType = headers["content-type"] ?? ""
        guard contentType.lowercased().contains("multipart"),
              let boundary = Self.boundary(in: contentType) else {
            return decodeTransfer(body, encoding: headers["content-transfer-encoding"])
        }

        var best: (isPlain: Bool, text: String)?
        for section in body.components(separatedBy: "--\(boundary)") {
            let (partHeaders, partBody) = splitHeaders(section)
            let type = (partHeaders["content-type"] ?? "").lowercased()
            guard type.contains("text/") else { continue }
            let decoded = decodeTransfer(partBody, encoding: partHeaders["content-transfer-encoding"])
            let isPlain = type.contains("text/plain")
            if isPlain { return decoded }               // plain wins outright
            if best == nil { best = (false, stripTags(decoded)) }
        }
        return best?.text ?? decodeTransfer(body, encoding: headers["content-transfer-encoding"])
    }

    static func boundary(in contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var value = String(contentType[range.upperBound...])
        if let end = value.firstIndex(where: { $0 == ";" }) { value = String(value[..<end]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\n")).nilIfEmpty
    }

    static func decodeTransfer(_ text: String, encoding: String?) -> String {
        switch (encoding ?? "").lowercased().trimmed {
        case "base64":
            let joined = text.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let data = Data(base64Encoded: joined, options: .ignoreUnknownCharacters)
            else { return text }
            return decodeText(data)
        case "quoted-printable":
            return decodeQuotedPrintable(text)
        default:
            return text
        }
    }

    static func decodeQuotedPrintable(_ text: String) -> String {
        // Soft line breaks first, then =XX escapes.
        var out = text.replacingOccurrences(of: "=\n", with: "")
        var bytes: [UInt8] = []
        var index = out.startIndex
        while index < out.endIndex {
            let character = out[index]
            if character == "=", out.index(index, offsetBy: 2, limitedBy: out.endIndex) != nil {
                let start = out.index(after: index)
                let hex = String(out[start..<out.index(start, offsetBy: 2)])
                if let byte = UInt8(hex, radix: 16) {
                    bytes.append(byte)
                    index = out.index(index, offsetBy: 3)
                    continue
                }
            }
            bytes.append(contentsOf: Array(String(character).utf8))
            index = out.index(after: index)
        }
        out = String(decoding: bytes, as: UTF8.self)
        return out
    }

    /// Decodes RFC 2047 `=?utf-8?B?...?=` header words so subjects aren't gibberish.
    static func decodeEncodedWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var result = text
        let pattern = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#)
        guard let pattern else { return text }
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text),
                  let kindRange = Range(match.range(at: 2), in: text),
                  let payloadRange = Range(match.range(at: 3), in: text) else { continue }
            let payload = String(text[payloadRange])
            let decoded: String
            if text[kindRange].lowercased() == "b" {
                decoded = Data(base64Encoded: payload).map { decodeText($0) } ?? payload
            } else {
                decoded = decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
            }
            result = result.replacingOccurrences(of: String(text[whole]), with: decoded)
        }
        return result
    }

    static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    /// Drops the quoted thread below a reply. Keeping it would duplicate text across
    /// every message in a conversation and skew every count that touches the corpus.
    static func stripQuotedReply(_ block: String) -> String {
        let lines = block.components(separatedBy: "\n")
        let quoted = lines.filter { $0.hasPrefix(">") }.count
        if quoted > 0, Double(quoted) / Double(max(1, lines.count)) > 0.6 { return "" }
        return lines.filter { !$0.hasPrefix(">") }.joined(separator: "\n")
    }

    static func attachmentNames(_ message: String) -> [String]? {
        let pattern = try? NSRegularExpression(pattern: #"filename="?([^"\r\n;]+)"?"#)
        guard let pattern else { return nil }
        let names = pattern.matches(in: message, range: NSRange(message.startIndex..., in: message))
            .compactMap { Range($0.range(at: 1), in: message).map { String(message[$0]).trimmed } }
        return Array(Set(names)).sorted()
    }
}
