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

        var fields: [[String: Any]] = truth.facts.enumerated().map { index, fact in
            // Sometimes cite an anchor that isn't on this document.
            let cited = (roll() < noise * 0.3) ? "e9999" : (anchors.indices.contains(index) ? anchors[index] : anchor)
            return ["name": "fact_\(index)", "value": fact, "source": cited]
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
