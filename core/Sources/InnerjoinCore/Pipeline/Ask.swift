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
    let maxOutputTokens = 1_200

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
        let reply = try AnswerReply(data: data)

        var citations: [Citation] = []
        var invented = 0
        var seen = Set<String>()
        for proposed in reply.citations {
            guard let documentID = Ask.documentID(from: proposed.document),
                  let element = elements[documentID]?[proposed.element.trimmed],
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
                    let anchor = field.source.map { " [\($0)]" } ?? ""
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
                lines.append(indent(String(markdown.prefix(maxCharactersPerExcerpt))))
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
        - Cite everything. Each citation is a document reference and an element anchor \
        from that same document, e.g. document "d3", element "e12". Never cite an anchor \
        that isn't shown under that document.
        - Answer in two or three sentences, in plain language. Name the documents by \
        their titles, not by their references.
        - Copy figures, dates, and names exactly as they appear. Do not convert \
        currencies or reformat dates.
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
                "items": [
                    "type": "object",
                    "properties": [
                        "document": ["type": "string", "description": "The document reference, e.g. d3."],
                        "element": ["type": "string", "description": "An anchor from that document, e.g. e12."],
                    ],
                    "required": ["document", "element"],
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
        var document: String
        var element: String
    }

    init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(AnswerReply.self, from: data)
        } catch {
            throw ProviderError.malformed("\(error)")
        }
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
