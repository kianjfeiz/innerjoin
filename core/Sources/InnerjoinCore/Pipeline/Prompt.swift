import Foundation

/// The Stage 3 prompt and its output contract.
///
/// Kept in one place so the schema, the instructions, and the decoder can't drift
/// apart — a mismatch between them is silent and shows up as missing facts.
enum Prompt {

    /// What the library has learned so far, handed back to the model.
    ///
    /// This is the whole of innerjoin's "training": no weights change, but each
    /// document is read with the benefit of every document read before it. The
    /// vocabulary a category has settled on, and one worked example from it, do more
    /// to make the hundredth invoice match the first than any amount of instruction.
    struct Learned {
        var categories: [String] = []
        var fieldNames: [String] = []
        var exemplar: Record?

        static let none = Learned()
    }

    /// Stable across documents, so providers that cache prompt prefixes get to.
    /// The taxonomy goes here for the same reason.
    static func system(categories: [String]) -> String {
        system(Learned(categories: categories))
    }

    static func system(_ learned: Learned) -> String {
        let categories = learned.categories
        // A real run proposed "spending_report" and "Itinerarys" as categories, and the
        // library ended up filed by document type rather than by what the documents are
        // about. `kind` already carries the document type; `category` is the shelf a
        // person would keep it on, and there are only ever a handful of those.
        let known = categories.isEmpty
            ? """
              There are no categories yet. Propose the area of life this belongs to — \
              the shelf someone would keep it on, like Apartment, Health, Travel, \
              Vehicle, Taxes, Work, Supplies. One or two plain words. Never a document \
              type: "Invoice", "Itinerary" and "spending_report" are kinds, not areas.
              """
            : "Categories in use: " + categories.joined(separator: ", ") +
              """
              . Reuse one of these when it fits — that is almost always the right answer. \
              Propose a new one only when the document belongs to a genuinely different \
              area of life, and then make it an area, not a document type.
              """

        var learnedBlock = ""
        if !learned.fieldNames.isEmpty {
            learnedBlock += """


                KNOWN FIELD NAMES: \(learned.fieldNames.joined(separator: ", "))
                Reuse one of those names exactly when it means the same thing. Only \
                invent a name for something genuinely new — a second name for the same \
                fact splits one column into two and makes the values impossible to \
                compare.
                """
        }
        if let exemplar = learned.exemplar, !exemplar.fields.isEmpty {
            let sample = exemplar.fields.sorted { $0.key < $1.key }.prefix(6)
                .map { "  \($0.key): \($0.value.value)" }.joined(separator: "\n")
            learnedBlock += """


                A previous document of this kind was read as:
                  title: \(exemplar.title)
                \(sample)
                Match that shape where this document supports it.
                """
        }

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
        - Every entity needs a `relation` saying what it is to this document, not just \
        that it appears in it:
            party_to    — a signatory or counterparty: a tenant, a lessor, a contractor
            issued_by   — who wrote or issued it: the vendor on an invoice, the insurer
            paid_to     — who receives the money
            employed_by — the employer, on an offer letter, contract or payslip
            governs     — the authority whose rules apply
            covers      — who or what a policy protects
            located_at  — an address the document is about
            owns        — the owner of the thing described
            When two fit, take the more specific. An offer letter is issued by the \
        employer *and* establishes employment: that is `employed_by`, not `issued_by`.
            mentions    — none of the above. Use it only when nothing more specific is \
        true; a document almost always has at least one party that isn't a mere mention.
        - Entities are the people, organizations, and places the document is *about* — \
        not every name that appears in it. A named party, yes. The city it was signed \
        in, the bank in the footer, the notary, a job title like "Tenant" — no. Most \
        documents have between one and five. Returning more is usually a mistake.
        - Nobody in a signature or filing block is a party. A notary, a witness, a \
        recording clerk, a title or escrow company, an agent, a preparer — these \
        processed the paperwork, they are not who it is between. A real run named a \
        title company as a party to a deed; it is not one.
        - Copy names as the document writes them, in the same case. Do not shout a name \
        that the document sets in capitals for design reasons.
        - If the document states a notice period in days, put the number in \
        `notice_days`. Do not calculate the deadline; that is done for you.
        - Copy what the document says even when it is wrong, and say so in `problems`. \
        If an invoice lists 2 x $389 as $877, the field value is $877 — what is printed — \
        and `problems` gets an entry saying the line does not multiply out. Never silently \
        correct a figure: the value and the page it came from have to agree, or a citation \
        means nothing. Report a total that does not match its lines, a count that does not \
        match the list, a date that cannot exist ("April 45"), dates in an impossible \
        order, a duplicated row or identifier, and any place the document states two \
        different values for one fact. Report nothing you had to assume.
        - Two things that are never problems: the *order of rows* in a table or list — a \
        file is not required to be sorted — and a value that merely looks unusual. Before \
        writing a `problems` entry, do the arithmetic: if the two sides agree, there is \
        nothing to report. Three or four real findings are worth more than twenty, and a \
        long list buries whatever mattered.
        - `assertions` are durable facts *about the people and organizations named*, \
        as opposed to facts about the document. "The total is $311.25" is a field. \
        "Joanna works at Acme" is an assertion — it stays true after this document is \
        filed away, and the next document about Joanna should agree with it. Résumés, \
        letterheads, signature blocks and email headers are full of these. Emit one per \
        fact, with `subject` copied exactly from `entities`:
          {"subject": "Joanna Ramirez", "predicate": "works_at", "object": "Acme", "source": "e4"}
          {"subject": "Joanna Ramirez", "predicate": "email", "object": "joanna@acme.com", "source": "e2"}
        When the document gives dates for a fact — a job that ran from one date to \
        another — put them in `since` and `until`. Omit `until` when it is still the \
        case. A document listing several jobs must date them, or there is no way to \
        tell which one is current.
        For `works_at`, `located_in`, `owns`, `member_of` and `related_to`, the object \
        must also be listed in `entities`. Return an empty list if the document states \
        nothing durable about anyone.\(learnedBlock)
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
    /// Which optional jobs this prompt is doing. Every addition competes for the model's
    /// attention with the extraction it was built for, and "competes" is a claim that
    /// should be measured rather than assumed — so each one can be switched off and the
    /// difference read off the eval.
    struct Jobs {
        var problems = true
        var assertions = true

        static var fromEnvironment: Jobs {
            let environment = ProcessInfo.processInfo.environment
            return Jobs(problems: environment["IJ_NO_PROBLEMS"] == nil,
                        assertions: environment["IJ_NO_ASSERTIONS"] == nil)
        }
    }

    static var schema: [String: Any] {
        var schema = fullSchema
        var properties = schema["properties"] as? [String: Any] ?? [:]
        var required = schema["required"] as? [String] ?? []
        let jobs = Jobs.fromEnvironment
        if !jobs.problems {
            properties.removeValue(forKey: "problems")
            required.removeAll { $0 == "problems" }
        }
        if !jobs.assertions {
            properties.removeValue(forKey: "assertions")
            required.removeAll { $0 == "assertions" }
        }
        schema["properties"] = properties
        schema["required"] = required
        return schema
    }

    static var fullSchema: [String: Any] { [
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
            "problems": [
                "type": "array",
                "description": "Ways this document contradicts itself. Empty if none.",
                "items": [
                    "type": "object",
                    "properties": [
                        "kind": [
                            "type": "string",
                            "enum": ["arithmetic", "count_mismatch", "contradiction",
                                     "impossible_date", "date_order", "duplicate", "other"],
                        ],
                        "detail": ["type": "string", "description": "One plain sentence naming both values."],
                        "source": ["type": "string", "description": "The [eN] anchor."],
                    ],
                    "required": ["kind", "detail"],
                ],
            ],
            "assertions": [
                "type": "array",
                "description": "Durable facts about people and organizations named here.",
                "items": [
                    "type": "object",
                    "properties": [
                        "subject": ["type": "string", "description": "The entity's name, exactly as in `entities`."],
                        // Closed, like relations and for the same reason: an open list
                        // gets four spellings of "employer" and stops being queryable.
                        "predicate": [
                            "type": "string",
                            "enum": ["works_at", "role", "email", "phone", "located_in",
                                     "related_to", "owns", "member_of"],
                        ],
                        "object": ["type": "string", "description": "The other name, or the plain value."],
                        "since": ["type": "string", "description": "When it began, if stated. YYYY-MM-DD or YYYY-MM."],
                        "until": ["type": "string", "description": "When it ended. Omit entirely if it is still the case."],
                        "source": ["type": "string", "description": "The [eN] anchor."],
                    ],
                    "required": ["subject", "predicate", "object"],
                ],
            ],
            "entities": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "kind": ["type": "string", "enum": ["person", "org", "place", "product", "account"]],
                        // A closed list on purpose. Left open, models invent
                        // party_to / is_party / signatory_of / party for the same
                        // relationship, and the graph becomes unqueryable.
                        "relation": [
                            "type": "string",
                            "enum": ["party_to", "issued_by", "paid_to", "governs", "covers",
                                     "located_at", "employed_by", "owns", "mentions"],
                        ],
                        "source": ["type": "string"],
                    ],
                    "required": ["name", "kind", "relation"],
                ],
            ],
        ],
        "required": ["title", "summary", "fields", "dates", "entities", "assertions"],
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
    var assertions: [ProposedAssertion]
    var problems: [ProposedProblem]

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
    struct ProposedProblem: Decodable, Sendable {
        var kind: String
        var detail: String
        var source: String?
    }
    struct ProposedAssertion: Decodable {
        var subject: String
        var predicate: String
        var object: String
        var since: String?
        var until: String?
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
        case assertions, problems
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
        assertions = (try? container.decodeIfPresent([ProposedAssertion].self, forKey: .assertions)) as? [ProposedAssertion] ?? []
        problems = (try? container.decodeIfPresent([ProposedProblem].self, forKey: .problems)) as? [ProposedProblem] ?? []
    }
}
