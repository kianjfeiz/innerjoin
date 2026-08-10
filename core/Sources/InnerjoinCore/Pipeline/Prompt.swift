import Foundation

/// The Stage 3 prompt and its output contract.
///
/// Kept in one place so the schema, the instructions, and the decoder can't drift
/// apart — a mismatch between them is silent and shows up as missing facts.
enum Prompt {

    /// Stable across documents, so providers that cache prompt prefixes get to.
    /// The taxonomy goes here for the same reason.
    static func system(categories: [String]) -> String {
        let known = categories.isEmpty
            ? "There are no categories yet — propose the one that fits."
            : "Categories in use: " + categories.joined(separator: ", ") +
              ". Reuse one of these when it fits; propose a new one only when none does."

        return """
        You read a document and return what it says as structured data.

        \(known)

        Rules:
        - Every field, date, and entity must cite the `[eN]` anchor it came from. If a \
        fact has no anchor nearby, leave it out. Never invent an anchor.
        - Copy values as they appear. Do not convert currencies, recompute totals, or \
        infer dates that aren't stated.
        - Field names are lower_snake_case and reusable across similar documents: \
        rent_monthly, invoice_number, policy_number, due_date, vendor.
        - `title` names the document as a person would refer to it, not the filename.
        - `summary` is one or two sentences, plain and specific.
        - Entities are the people, organizations, and places the document is *about* — \
        not every name that appears in it.
        - If the document states a notice period in days, put the number in \
        `notice_days`. Do not calculate the deadline; that is done for you.
        """
    }

    static func user(name: String, markdown: String) -> String {
        """
        File: \(name)

        ---
        \(markdown)
        """
    }

    /// The output contract. Values are strings so the shape stays portable across
    /// providers; the two things innerjoin queries on, `amount` and dates, are typed.
    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "How a person would refer to this document."],
            "kind": ["type": "string", "description": "lease, invoice, policy, receipt, memo, note…"],
            "summary": ["type": "string"],
            "category": ["type": "string"],
            "happened_on": ["type": "string", "description": "The date the document is about, YYYY-MM-DD."],
            "amount": ["type": "number", "description": "The single most important amount, if there is one."],
            "currency": ["type": "string", "description": "ISO code, e.g. USD."],
            "notice_days": ["type": "integer", "description": "Notice period in days, if the document states one."],
            "fields": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "value": ["type": "string"],
                        "unit": ["type": "string"],
                        "source": ["type": "string", "description": "The [eN] anchor, e.g. e12."],
                    ],
                    "required": ["name", "value", "source"],
                ],
            ],
            "dates": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "description": "term_end, expires, due, renewal, signed…"],
                        "date": ["type": "string", "description": "YYYY-MM-DD."],
                        "source": ["type": "string"],
                    ],
                    "required": ["kind", "date"],
                ],
            ],
            "entities": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "kind": ["type": "string", "enum": ["person", "org", "place", "product", "account"]],
                        "relation": [
                            "type": "string",
                            "description": "party_to, issued_by, paid_to, governs, covers, located_at, mentions…",
                        ],
                        "source": ["type": "string"],
                    ],
                    "required": ["name", "kind"],
                ],
            ],
        ],
        "required": ["title", "summary", "fields", "dates", "entities"],
    ] }
}

/// The decoded reply. Everything optional except what the schema requires, because a
/// model omitting a field should cost that field, not the whole document.
struct Reply: Decodable {
    var title: String
    var kind: String?
    var summary: String?
    var category: String?
    var happenedOn: String?
    var amount: Double?
    var currency: String?
    var noticeDays: Int?
    var fields: [ProposedField]
    var dates: [ProposedDate]
    var entities: [ProposedEntity]

    struct ProposedField: Decodable {
        var name: String
        var value: String
        var unit: String?
        var source: String?
    }
    struct ProposedDate: Decodable {
        var kind: String
        var date: String
        var source: String?
    }
    struct ProposedEntity: Decodable {
        var name: String
        var kind: String?
        var relation: String?
        var source: String?
    }

    enum CodingKeys: String, CodingKey {
        case title, kind, summary, category, amount, currency, fields, dates, entities
        case happenedOn = "happened_on"
        case noticeDays = "notice_days"
    }

    init(data: Data) throws {
        do {
            let decoder = JSONDecoder()
            var reply = try decoder.decode(Reply.self, from: data)
            reply.fields = reply.fields.filter { !$0.name.trimmed.isEmpty }
            self = reply
        } catch {
            throw ProviderError.malformed("\(error)")
        }
    }
}

extension Reply {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        category = try? container.decodeIfPresent(String.self, forKey: .category)
        happenedOn = try? container.decodeIfPresent(String.self, forKey: .happenedOn)
        amount = try? container.decodeIfPresent(Double.self, forKey: .amount)
        currency = try? container.decodeIfPresent(String.self, forKey: .currency)
        noticeDays = try? container.decodeIfPresent(Int.self, forKey: .noticeDays)
        fields = (try? container.decodeIfPresent([ProposedField].self, forKey: .fields)) as? [ProposedField] ?? []
        dates = (try? container.decodeIfPresent([ProposedDate].self, forKey: .dates)) as? [ProposedDate] ?? []
        entities = (try? container.decodeIfPresent([ProposedEntity].self, forKey: .entities)) as? [ProposedEntity] ?? []
    }
}
