import Foundation
import InnerjoinCore

/// Stands in for a real model, and behaves like one on a bad day.
///
/// The point isn't to check that a model is clever — that needs a key and real
/// documents. It's to check that the *engine* holds up when the model is imperfect,
/// which is the normal case. So this deliberately does the things models actually do:
/// name the scenery, abbreviate a company one time and spell it out the next, guess a
/// category wrongly now and then, and occasionally cite an anchor that doesn't exist.
struct Simulator: ModelProvider {
    let expected: [String: Corpus.Expected]
    /// 0 = a flawless model, 1 = every failure mode on every document.
    let noise: Double

    var label: String { "Simulator (noise \(Int(noise * 100))%)" }

    func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data {
        // Answering is a different job with a different contract, so it gets its own
        // stand-in. This one validates the *harness* — that retrieval put the right
        // document in front of the model, that a citation resolves, that refusal works,
        // that scoring counts it all correctly. It cannot validate the model's
        // reasoning, and doesn't pretend to: it only reports what is demonstrably
        // present in the material it was handed.
        if system.hasPrefix("You answer questions") {
            return try answer(user)
        }

        guard let truth = match(user) else {
            return try JSONSerialization.data(withJSONObject: [
                "title": "Untitled", "summary": "No ground truth for this document.",
                "fields": [], "dates": [], "entities": [],
            ])
        }
        // Deterministic per document, so a run is reproducible and a regression is real.
        var seed = UInt64(abs(truth.file.hashValue) % 100_000)
        func roll() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 1000) / 1000.0
        }

        let anchors = Self.anchors(in: user)
        let anchor = anchors.first ?? "e0"

        var entities: [[String: Any]] = truth.entities.map { name in
            // Models abbreviate. Half the time a long name arrives shortened, which is
            // what stage 4's merging has to survive.
            let written = (roll() < noise * 0.5 && name.contains(" "))
                ? String(name.split(separator: " ").first!)
                : name
            return ["name": written, "kind": Self.kind(of: name),
                    "relation": "party_to", "source": anchor]
        }
        // Scenery: roles, cities, states the document happens to mention.
        if roll() < noise {
            for extra in truth.scenery {
                entities.append(["name": extra, "kind": "place", "relation": "mentions", "source": anchor])
            }
        }

        // In-context learning, modelled honestly. Told which name a category already
        // uses for a fact, a model reuses it; left to itself it picks a plausible
        // synonym that differs from document to document. That drift is the thing the
        // learned vocabulary exists to stop, so the simulator has to exhibit it.
        let suggested = Self.suggestedNames(in: system)
        var fields: [[String: Any]] = truth.facts.enumerated().map { index, fact in
            let cited = (roll() < noise * 0.3) ? "e9999" : (anchors.indices.contains(index) ? anchors[index] : anchor)
            let variants = Corpus.synonyms[fact.concept] ?? [fact.concept]
            let name: String
            if let honoured = variants.first(where: { suggested.contains($0) }) {
                name = honoured
            } else {
                // No guidance: settle on a variant chosen by this document alone.
                name = variants[Int(seed % UInt64(variants.count))]
            }
            return ["name": name, "value": fact.value, "source": cited]
        }
        fields.append(["name": "source_file", "value": truth.file, "source": anchor])

        // The category guess: usually right, sometimes missing, occasionally wrong.
        var category: String? = truth.area
        let categoryRoll = roll()
        if categoryRoll < noise * 0.25 { category = nil }
        else if categoryRoll < noise * 0.35 { category = "Miscellaneous" }

        var payload: [String: Any] = [
            "title": "\(truth.area): \(truth.file)",
            "kind": Self.documentKind(truth.area),
            "summary": "A \(truth.area.lowercased()) document.",
            "fields": fields, "dates": [], "entities": entities,
        ]
        if let category { payload["category"] = category }
        if let date = Self.firstDate(in: user) {
            payload["happened_on"] = date
            payload["dates"] = [["kind": "mentioned", "date": date, "source": anchor]]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Field names the prompt offered, pulled back out of the text the way a model
    /// would attend to them.
    static let marker = "KNOWN FIELD NAMES:"

    static func suggestedNames(in system: String) -> Set<String> {
        guard let line = system.components(separatedBy: "\n")
            .first(where: { $0.contains(marker) }),
              let range = line.range(of: marker) else { return [] }
        return Set(line[range.upperBound...]
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    /// The prompt carries the filename, which is how a document is identified here.
    private func match(_ prompt: String) -> Corpus.Expected? {
        expected.first { prompt.contains($0.key) }?.value
    }

    static func kind(of name: String) -> String {
        if name.first?.isNumber == true { return "place" }
        if name.contains(" ") && (name.hasSuffix("Inn") || name.contains("Air")
            || name.contains("Clinic") || name.contains("Laboratories")
            || name.contains("Farm") || name.contains("Electric")
            || name.contains("Care")) { return "org" }
        return "person"
    }

    static func documentKind(_ area: String) -> String {
        switch area {
        case "Apartment": "lease"
        case "Supplies":  "invoice"
        case "Health":    "policy"
        case "Travel":    "booking"
        default:          "note"
        }
    }

    /// Answers from the material, and only from the material.
    ///
    /// Finds the question among the corpus's known ones, then checks whether its answer
    /// is actually present in what retrieval supplied. Present → answer and cite the
    /// anchor on the line it was found on. Absent → refuse. That is exactly the
    /// behaviour the real prompt asks for, so the harness can be verified before a real
    /// model is ever called.
    private func answer(_ user: String) throws -> Data {
        let asked = Self.questionText(in: user)
        let question = Corpus.questions.first {
            $0.text.compare(asked, options: .caseInsensitive) == .orderedSame
        }

        // Nothing known about it, or nothing to find: refusing is correct.
        guard let question, !question.unanswerable,
              let line = Self.line(containing: question.expected, in: user)
        else {
            return try JSONSerialization.data(withJSONObject: [
                "answered": false,
                "answer": "Nothing in the material provided covers that.",
                "citations": [],
            ])
        }

        // Cite the anchor on the line the value came from when there is one; otherwise
        // the document's first anchor, which is what a careful reader would do.
        // Citations are now one token, "d3:e12", copied from the material.
        let tokenOnLine = Self.citeTokens(in: line).first
        let token = tokenOnLine ?? Self.citeTokens(in: user).first
        let document = Self.documentReference(before: question.expected, in: user)

        var citations: [[String: String]] = []
        if let token { citations = [["cite": token]] }

        return try JSONSerialization.data(withJSONObject: [
            "answered": true,
            "answer": "\(question.expected) — from \(document ?? "the library").",
            "citations": citations,
        ])
    }

    private static func questionText(in user: String) -> String {
        guard let line = user.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Question:") }) else { return "" }
        return String(line.dropFirst("Question:".count))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func line(containing needle: String, in text: String) -> String? {
        text.components(separatedBy: .newlines).first { $0.contains(needle) }
    }

    /// Which document block a value sits in: the last `[dN]` header above it.
    private static func documentReference(before needle: String, in text: String) -> String? {
        var current: String?
        for line in text.components(separatedBy: .newlines) {
            if let match = matches(#"^\[(d\d+)\]"#, in: line, group: 1).first { current = match }
            if line.contains(needle) { return current }
        }
        return nil
    }

    /// The `[dN:eM]` tokens the material offers.
    static func citeTokens(in text: String) -> [String] {
        matches(#"\[(d\d+:e\d+)\]"#, in: text, group: 1)
    }

    static func anchors(in text: String) -> [String] {
        matches(#"\[(e\d+)\]"#, in: text, group: 1)
    }

    static func firstDate(in text: String) -> String? {
        matches(#"\d{4}-\d{2}-\d{2}"#, in: text, group: 0).first
    }

    static func matches(_ pattern: String, in text: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: group), in: text).map { String(text[$0]) } }
    }
}
