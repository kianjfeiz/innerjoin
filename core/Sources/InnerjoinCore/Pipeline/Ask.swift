import Foundation
import GRDB

/// Answers a question from the library, and shows its work.
///
/// This is the other half of the point. Reading documents accurately is worth nothing if
/// you can't then ask about them, and a chat window that answers confidently from
/// nothing is worse than no chat window at all. So the contract here is narrow:
///
/// - The model sees only what retrieval found. It is not asked what it knows.
/// - Every claim carries a citation, and a citation that doesn't resolve to a real
///   element of a real document is dropped before anyone sees it.
/// - When the library doesn't contain the answer, saying so is the correct response.
///   `answered == false` is a success, not a failure.
/// - No arithmetic across documents. It reports the figures it found; adding them up is
///   the app's job, where the sum can be shown alongside its parts.
public struct Ask: Sendable {
    let store: Store
    let provider: any ModelProvider

    /// How many documents to put in front of the model. Enough to answer across a few
    /// documents, few enough that the prompt stays cheap and focused.
    let breadth: Int
    /// The closest few also contribute their text, not just their extracted fields —
    /// fields answer "how much is the rent", the text answers everything else.
    let deepReadCount = 3
    let maxCharactersPerExcerpt = 3_000
    // Headroom, so a model that thinks before it writes still has room to write.
    let maxOutputTokens = 2_500

    public init(store: Store, provider: any ModelProvider, breadth: Int = 8) {
        self.store = store
        self.provider = provider
        self.breadth = breadth
    }

    public struct Citation: Sendable, Equatable {
        public let documentID: Int64
        public let documentLabel: String
        public let elementTag: String
        public let page: Int?
        public let box: BBox?
        /// The text actually at that anchor, so a citation can be shown, not just linked.
        public let quote: String
    }

    public struct Answer: Sendable {
        public let question: String
        public let text: String
        /// True when the library contained enough to answer. False is a real answer:
        /// "nothing here says that" beats a confident invention.
        public let answered: Bool
        public let citations: [Citation]
        /// Citations the model made up, which were dropped. Watched, not hidden.
        public let invented: Int
        /// What retrieval put in front of the model, so the reasoning is inspectable.
        public let consulted: [(id: Int64, label: String, matchedRecord: Bool)]
    }

    public func answer(_ question: String) async throws -> Answer {
        let hits = try store.retrieve(question, limit: breadth)
        guard !hits.isEmpty else {
            return Answer(question: question,
                          text: "Nothing in the library mentions that.",
                          answered: false, citations: [], invented: 0, consulted: [])
        }

        // Every element of every consulted document, so a citation can be checked and
        // then resolved to its page and box without a second trip.
        var elements: [Int64: [String: Element]] = [:]
        for hit in hits {
            guard let id = hit.document.id else { continue }
            elements[id] = Dictionary(
                try store.elements(of: id).map { ($0.tag, $0) },
                uniquingKeysWith: { first, _ in first })
        }

        let context = try material(for: hits)
        let data = try await provider.extract(
            system: Ask.system,
            user: "Question: \(question)\n\n---\n\(context)",
            schema: Ask.schema,
            maxTokens: maxOutputTokens
        )
        // Models occasionally answer in prose despite the schema. The words are still
        // a good answer and they still carry their `d3:e12` tokens, so salvaging beats
        // failing the question — and every token is verified below either way.
        let reply = (try? AnswerReply(data: data))
            ?? AnswerReply(salvaging: String(data: data, encoding: .utf8) ?? "")

        var citations: [Citation] = []
        var invented = 0
        var seen = Set<String>()
        for proposed in reply.citations {
            guard let (documentReference, elementReference) = Ask.split(proposed.cite),
                  let documentID = Ask.documentID(from: documentReference),
                  let tag = Element.normalizeTag(elementReference),
                  let element = elements[documentID]?[tag],
                  let document = hits.first(where: { $0.document.id == documentID })?.document
            else { invented += 1; continue }

            let key = "\(documentID):\(element.tag)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            citations.append(Citation(
                documentID: documentID, documentLabel: document.label,
                elementTag: element.tag, page: element.page, box: element.box,
                quote: String(element.text.prefix(240))))
        }

        return Answer(
            question: question,
            text: reply.answer.trimmed,
            // A claim with no surviving citation isn't an answer we should present as one.
            answered: reply.answered && !reply.answer.trimmed.isEmpty,
            citations: citations, invented: invented,
            consulted: hits.compactMap { hit in
                hit.document.id.map { ($0, hit.document.label, hit.matchedRecord) }
            })
    }

    // MARK: - What the model is allowed to see

    /// The retrieved documents, as records first and text second.
    ///
    /// A record is a compressed, already-verified reading of a document, so leading with
    /// it means the model spends its attention on the question rather than on re-reading
    /// the paperwork. The nearest few also carry an excerpt, because a question can
    /// always be about something extraction didn't think to pull out.
    private func material(for hits: [Store.Hit]) throws -> String {
        var blocks: [String] = []

        for (position, hit) in hits.enumerated() {
            guard let id = hit.document.id else { continue }
            var lines = ["[d\(id)] \(hit.document.label)"]

            if let record = hit.record {
                var header: [String] = []
                if let category = record.category { header.append(category) }
                if let date = record.happenedOn { header.append(Ask.day.string(from: date)) }
                if !header.isEmpty { lines.append("  " + header.joined(separator: " · ")) }
                if let summary = record.summary, !summary.isEmpty {
                    lines.append("  \(summary)")
                }
                for (name, field) in record.fields.sorted(by: { $0.key < $1.key }) {
                    let anchor = field.source.map { " [d\(id):\($0)]" } ?? ""
                    let unit = field.unit.map { " \($0)" } ?? ""
                    lines.append("  \(name): \(field.value)\(unit)\(anchor)")
                }
                if let recordID = record.id {
                    let dates = try store.dates(ofRecord: recordID)
                    for date in dates {
                        let derived = date.derived ? " (worked out, not stated)" : ""
                        lines.append("  \(date.kind): \(Ask.day.string(from: date.date))\(derived)")
                    }
                }
            } else {
                lines.append("  (not yet understood — text only)")
            }

            if position < deepReadCount, let markdown = hit.document.markdown {
                lines.append("  ---")
                // Anchors inside an excerpt are rewritten to carry their document too,
                // so every citable token in the whole prompt is unambiguous on its own.
                let owned = markdown.replacingOccurrences(
                    of: #"\[(e\d+)\]"#, with: "[d\(id):$1]", options: .regularExpression)
                lines.append(indent(String(owned.prefix(maxCharactersPerExcerpt))))
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private func indent(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { "  \($0)" }.joined(separator: "\n")
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "d3:e12" → ("d3", "e12"). Tolerates the brackets a model copies along with it.
    static func split(_ cite: String) -> (String, String)? {
        let cleaned = cite.trimmingCharacters(in: CharacterSet(charactersIn: " []()"))
        let parts = cleaned.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// "d12" → 12. Anything else is a citation that was never on offer.
    static func documentID(from reference: String) -> Int64? {
        let trimmed = reference.trimmed.lowercased()
        let digits = trimmed.hasPrefix("d") ? String(trimmed.dropFirst()) : trimmed
        return Int64(digits)
    }

    static let system = """
        You answer questions about someone's own documents, using only the material given \
        to you below.

        Rules:
        - Use only what is in the material. You have no other knowledge of this person's \
        affairs. If the material doesn't answer the question, set `answered` to false and \
        say plainly what's missing — that is the right answer, not a failure.
        - A document about a *neighbouring* subject is not an answer. Retrieval brings \
        you whatever came closest, and when the library doesn't hold the answer, what \
        came closest is something else entirely. Asked what someone paid for car \
        insurance, a vehicle registration fee is not the answer — it is a different \
        payment, to a different body, for a different thing. Asked for a passport \
        number, a policy number is not the answer. Before you answer, check that the \
        document you are about to cite is about the thing that was asked for, not merely \
        about a thing that shares a word with it. When it isn't, `answered` is false.
        - Cite everything. A citation is one of the `[dN:eM]` tokens shown in the \
        material, copied exactly — for example "d3:e12". Never write a token that does \
        not appear above; if a fact has no token beside it, say the fact and cite the \
        nearest token that does support it, or cite nothing.
        - Answer in two or three sentences, in plain language. Name the documents by \
        their titles, not by their references.
        - Copy figures, dates, and names exactly as they appear, character for \
        character. A date written 2026-06-01 must be written back as 2026-06-01, not as \
        "June 1, 2026" — the person reading it is checking it against the document.
        - Do not add anything up, average anything, or compute a difference. If several \
        documents each state an amount, report them individually and say they are \
        separate. Arithmetic across documents is done elsewhere, where the total can be \
        shown next to the figures it came from.
        - If the documents disagree, say so and cite both.
        """

    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "answered": [
                "type": "boolean",
                "description": "True only if the material actually answers the question.",
            ],
            "answer": [
                "type": "string",
                "description": "Two or three plain sentences. If answered is false, what's missing.",
            ],
            "citations": [
                "type": "array",
                "description": "The [dN:eM] tokens supporting the answer, copied exactly.",
                "items": [
                    "type": "object",
                    "properties": [
                        "cite": ["type": "string", "description": "One token, e.g. d3:e12."],
                    ],
                    "required": ["cite"],
                ],
            ],
        ],
        "required": ["answered", "answer", "citations"],
    ] }
}

struct AnswerReply: Decodable {
    var answered: Bool
    var answer: String
    var citations: [ProposedCitation]

    struct ProposedCitation: Decodable {
        var cite: String

        init(cite: String) { self.cite = cite }

        // Accept the older pair shape too — a model handed a schema will sometimes
        // answer in whatever shape it saw last, and losing a good citation to that is
        // worse than reading both.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let single = try? container.decode(String.self, forKey: .cite) {
                cite = single
            } else {
                let document = (try? container.decode(String.self, forKey: .document)) ?? ""
                let element = (try? container.decode(String.self, forKey: .element)) ?? ""
                cite = "\(document):\(element)"
            }
        }
        enum Keys: String, CodingKey { case cite, document, element }
    }

    init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(AnswerReply.self, from: data)
        } catch {
            throw ProviderError.malformed("\(error)")
        }
    }

    /// Reads an answer written as prose, keeping the citation tokens it mentions.
    init(salvaging text: String) {
        let trimmed = text.trimmed
        answer = trimmed
        answered = !trimmed.isEmpty
        let pattern = #"[\(\[]?(d\d+:e\d+)[\)\]]?"#
        let found = (try? NSRegularExpression(pattern: pattern))
            .map { regex in
                regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
                    .compactMap { Range($0.range(at: 1), in: trimmed).map { String(trimmed[$0]) } }
            } ?? []
        citations = found.map { ProposedCitation(cite: $0) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answer = (try? container.decode(String.self, forKey: .answer)) ?? ""
        answered = (try? container.decode(Bool.self, forKey: .answered)) ?? !answer.isEmpty
        citations = (try? container.decodeIfPresent([ProposedCitation].self, forKey: .citations))
            as? [ProposedCitation] ?? []
    }

    enum CodingKeys: String, CodingKey { case answered, answer, citations }
}
