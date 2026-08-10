import Foundation
import NaturalLanguage

/// Decides which proposed entities are real enough to put on the graph.
///
/// Models over-produce entities. Asked for "the people, organizations and places",
/// they return the notary, the city, the state, the bank in the footer, and the word
/// "Tenant" — and every one of those becomes a node that dilutes the graph. That
/// matters more than it sounds: categories are derived from graph structure, so a hub
/// entity linked to everything collapses clustering into one undifferentiated blob.
///
/// Nothing here asks a model anything. Four deterministic tests, then independent
/// corroboration from on-device named-entity recognition.
public struct EntityGate {
    /// Beyond this many entities from a single document, we're being told about
    /// scenery rather than subjects. Extras are dropped lowest-confidence first.
    public static let perDocumentLimit = 15

    let documentText: String
    private let normalizedText: String
    private let recognizedNames: Set<String>

    public init(documentText: String) {
        self.documentText = documentText
        self.normalizedText = Entity.normalize(documentText)
        self.recognizedNames = EntityGate.recognizeNames(in: documentText)
    }

    public enum Verdict {
        case admit(confidence: Double)
        case reject(String)
    }

    public func judge(name rawName: String, kind: Entity.Kind) -> Verdict {
        let name = rawName.trimmed
        let normalized = Entity.normalize(name)

        guard normalized.count >= 2 else { return .reject("too short") }
        guard name.rangeOfCharacter(from: .letters) != nil else { return .reject("no letters") }

        // "2026", "$3,200", "31 March" — quantities and dates are facts, not entities.
        if normalized.allSatisfy({ $0.isNumber || $0.isWhitespace }) {
            return .reject("just a number")
        }

        // A role isn't a party. "Tenant" appears in every lease and identifies nobody.
        if Self.roleWords.contains(normalized) { return .reject("generic role") }

        // Nor is the vocabulary of paperwork. Statement lines read like names —
        // "Deposit", "Refund", "Balance" — and each one admitted is a node that
        // means nothing and links documents that have nothing to do with each other.
        if Self.paperworkWords.contains(normalized) { return .reject("paperwork term") }

        // Roles are productive in English — policyholder, accountholder, co-signer —
        // so a list alone will always be a step behind. A single word built from a
        // role suffix is a role, not a name.
        if !normalized.contains(" "), Self.roleSuffixes.contains(where: { normalized.hasSuffix($0) }),
           normalized.count > 5 {
            return .reject("generic role")
        }

        // Whoever processed the paperwork is not a party to it. A deed names its notary,
        // its witness, its recording clerk and its title company; a real run proposed
        // three of those four as parties to a garage transfer. Asking the model nicely
        // didn't hold, and it can't — from inside the sentence "sworn before notary
        // J. Whitfield", the notary looks exactly like a person the document is about.
        // The document itself says which they are, right before the name.
        if let role = processingRole(before: name) {
            return .reject("named as the \(role)")
        }

        // Places have to be specific enough to be a subject. "1247 Fillmore St" is a
        // thing you can have a lease on; "California" is a hub waiting to happen.
        if Self.administrativeRegions.contains(normalized), !normalized.contains(where: \.isNumber) {
            return .reject("too broad a place")
        }

        // The strongest test: if the name isn't in the document, the model made it up.
        guard normalizedText.contains(normalized) else { return .reject("not in the document") }

        // Independent corroboration, free and on-device. Agreement isn't required —
        // recognition misses plenty — but it earns a higher confidence.
        let corroborated = recognizedNames.contains(normalized)
            || recognizedNames.contains { $0.contains(normalized) || normalized.contains($0) }
        return .admit(confidence: corroborated ? 1.0 : 0.75)
    }

    /// How often the name occurs, as a rough salience score. Used only to decide what
    /// survives the per-document cap.
    public func mentions(of name: String) -> Int {
        let normalized = Entity.normalize(name)
        guard !normalized.isEmpty else { return 0 }
        return normalizedText.components(separatedBy: normalized).count - 1
    }

    /// People, organizations, and places found by `NLTagger` — a second opinion that
    /// costs nothing and was arrived at without seeing the model's answer.
    private static func recognizeNames(in text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: Set<String> = []
        let wanted: [NLTag] = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if let tag, wanted.contains(tag) {
                let normalized = Entity.normalize(String(text[range]))
                if normalized.count >= 2 { found.insert(normalized) }
            }
            return true
        }
        return found
    }

    /// Roles, not identities. Every lease has a tenant; naming one tells you nothing.
    static let roleWords: Set<String> = [
        "tenant", "landlord", "lessee", "lessor", "buyer", "seller", "purchaser",
        "customer", "client", "employer", "employee", "borrower", "lender",
        "insured", "insurer", "company", "corporation", "party", "parties",
        "applicant", "recipient", "sender", "user", "account holder", "cardholder",
        "member", "patient", "provider", "contractor", "subcontractor", "owner",
        "occupant", "guarantor", "witness", "notary", "agent", "broker",
        "the undersigned", "undersigned", "vendor", "supplier", "bank", "landlords",
        "policyholder", "policy holder", "beneficiary", "dependent", "subscriber",
        "payee", "payer", "claimant", "signatory", "co-signer", "cosigner",
        "manager", "administrator", "trustee", "executor", "guardian", "operator",
        "passenger", "guest", "resident", "student", "staff", "team",
    ]

    /// English builds role nouns from a handful of endings; matching the ending keeps
    /// this from having to enumerate every one.
    static let roleSuffixes: [String] = ["holder", "payer", "payee", "signer", "writer"]

    /// Whether the document introduces this name as the person who *handled* it.
    ///
    /// Looks at the words immediately before the name, which is where the document says
    /// what someone's part in it was: "witnessed by R. Delacroix", "sworn before notary
    /// J. Whitfield", "recorded by clerk A. Nakamura", "title work by Golden Gate Title
    /// Company". Deliberately a short window — further back and an ordinary sentence
    /// starts matching.
    func processingRole(before name: String) -> String? {
        guard let range = documentText.range(of: name, options: [.caseInsensitive])
        else { return nil }
        let start = documentText.index(range.lowerBound,
                                       offsetBy: -min(60, documentText.distance(
                                           from: documentText.startIndex, to: range.lowerBound)))
        let lead = documentText[start..<range.lowerBound].lowercased()
        return Self.processingRoles.first { lead.contains($0) }
    }

    /// The parts people play in producing a document rather than being party to it.
    static let processingRoles: [String] = [
        "notary", "notarized by", "sworn before", "witness", "witnessed by",
        "recorded by", "clerk", "prepared by", "drafted by", "issued through",
        "title work by", "title company", "escrow", "attested", "certified by",
        "on behalf of", "agent for", "care of", "c/o",
    ]

    /// The words paperwork is made of. They turn up capitalised at the start of a
    /// statement line, which is exactly what a name looks like from the outside.
    static let paperworkWords: Set<String> = [
        "deposit", "withdrawal", "payment", "transfer", "refund", "credit", "debit",
        "balance", "invoice", "receipt", "statement", "total", "subtotal", "tax",
        "fee", "charge", "adjustment", "interest", "premium", "copay", "deductible",
        "rent", "utility", "utilities", "supplies", "service", "services",
        "description", "amount", "date", "quantity", "price", "notice", "terms",
        "agreement", "contract", "policy", "account", "reference", "summary",
    ]

    /// Regions coarse enough that nearly every document mentions one. Admitted only
    /// when the name also carries a number, which is what makes a street address.
    static let administrativeRegions: Set<String> = [
        "usa", "us", "united states", "united states of america", "canada", "mexico",
        "uk", "united kingdom", "england", "california", "ca", "new york", "ny",
        "texas", "tx", "florida", "fl", "washington", "wa", "oregon", "or",
        "nevada", "nv", "arizona", "az", "illinois", "il", "massachusetts", "ma",
        "san francisco", "los angeles", "new york city", "chicago", "seattle",
        "berkeley", "oakland", "boston", "austin", "denver", "miami",
    ]
}
