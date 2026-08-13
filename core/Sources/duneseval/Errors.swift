import Foundation
import DunesCore

/// Scores what the library notices is *wrong* with what it reads, against a corpus whose
/// faults are written down.
///
/// The corpus is 36 files across 12 formats, each carrying deliberate faults — impossible
/// dates, totals that don't add up, counts that contradict a list, transposed figures,
/// misspellings — and a manifest saying what was put where. That manifest is the truth
/// this scores against.
///
/// Counting flagged documents was the old measure and it flattered the system: a reader
/// that says "this date looks odd" about every file scores 100%. So each fault in the
/// manifest is scored on its own, and a fault counts as found only when a finding names
/// the same figure the manifest does. Faults the manifest describes without naming
/// anything checkable ("mixed date formats") can't be scored that way, so they are
/// reported separately rather than quietly counted as either.
enum Errors {
    struct Fault {
        let file: String
        let phrase: String
        /// Figures, dates and quoted words distinctive enough to recognise a finding by.
        let tokens: [String]
    }

    static func run(corpus: String, manifest: String) async throws {
        let settings = ProviderSettings.fromEnvironment()
        guard settings.kind != .mock else { print("--errors needs a provider."); exit(1) }

        let faults = try readManifest(at: manifest)
        guard !faults.isEmpty else { print("No manifest at \(manifest)."); return }

        let root = URL(fileURLWithPath: corpus)
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: corpus)
            .filter { !$0.hasPrefix(".") && !$0.contains("MANIFEST") }
            .map { root.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }

        print("Faults corpus · \(settings.makeProvider().label)")
        print("  \(files.count) files · \(faults.count) faults recorded in the manifest\n")

        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ijerrors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try Store(root: workspace)
        await Meter.shared.reset()

        let librarian = Librarian(store: store, provider: settings.makeProvider())
        let summary = try await librarian.absorb(files, settle: false)
        for problem in summary.problems { print("  ! \(problem.file): \(problem.reason)") }

        // What was found, gathered per file so a finding is only credited against the
        // faults of the document it came from.
        var found: [String: String] = [:]
        var findings = 0
        for (document, anomalies) in try store.flagged(limit: 500) {
            let name = (document.name as NSString).lastPathComponent
            found[name, default: ""] += " " + anomalies.map(\.detail).joined(separator: " ")
            findings += anomalies.count
        }

        var scoreable = 0, caught = 0
        var byFormat: [String: (total: Int, caught: Int)] = [:]
        var missed: [String] = []
        for fault in faults {
            let format = (fault.file as NSString).pathExtension
            guard !fault.tokens.isEmpty else { continue }
            scoreable += 1
            let reported = found[fault.file] ?? ""
            let hit = fault.tokens.contains { reported.localizedCaseInsensitiveContains($0) }
            byFormat[format, default: (0, 0)].total += 1
            if hit {
                caught += 1
                byFormat[format]!.caught += 1
            } else if missed.count < 12 {
                missed.append("\(fault.file): \(fault.phrase.prefix(70))")
            }
        }

        print("── faults · what the reader noticed " + String(repeating: "─", count: 26))
        print("  documents flagged     \(percent(found.count, files.count))   \(found.count)/\(files.count)")
        print("  findings               \(findings)")
        print("  faults caught by name \(percent(caught, scoreable))   \(caught)/\(scoreable) checkable")
        print("  unscoreable            \(faults.count - scoreable) described without a figure to match on\n")

        print("  \(pad("format", 10))caught")
        for (format, tally) in byFormat.sorted(by: { $0.key < $1.key }) {
            print("  \(pad(format, 10))\(percent(tally.caught, tally.total))   \(tally.caught)/\(tally.total)")
        }
        if !missed.isEmpty {
            print("\n  missed:")
            for entry in missed { print("    \(entry)") }
        }
        let spend = await Meter.shared.snapshot()
        print("\n  cost: \(spend.description)")
    }

    /// Reads the manifest's per-file bullets into individual faults.
    ///
    /// The manifest is *data*, not instruction: only figures and quoted words are taken
    /// from it, and they are used as strings to compare against.
    static func readManifest(at path: String) throws -> [Fault] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var faults: [Fault] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- **"),
                  let close = trimmed.range(of: "**", range: trimmed.index(trimmed.startIndex, offsetBy: 4)..<trimmed.endIndex)
            else { continue }
            let file = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<close.lowerBound])
            let rest = String(trimmed[close.upperBound...])
            for phrase in rest.components(separatedBy: ";") {
                let clean = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " —-"))
                guard !clean.isEmpty else { continue }
                faults.append(Fault(file: file, phrase: clean, tokens: distinctiveTokens(in: clean)))
            }
        }
        return faults
    }

    /// The parts of a description a finding could be recognised by: quoted words, and
    /// figures long enough not to appear by chance.
    static func distinctiveTokens(in phrase: String) -> [String] {
        var tokens: [String] = []
        var quoted = false, current = ""
        for character in phrase {
            if character == "\"" {
                if quoted, current.count >= 3 { tokens.append(current) }
                quoted.toggle(); current = ""
            } else if quoted {
                current.append(character)
            }
        }
        // Figures, kept with their punctuation so "12.25" and "2024-02-30" stay whole.
        var number = ""
        for character in phrase {
            if character.isNumber || ((character == "." || character == "-" || character == ",") && !number.isEmpty) {
                number.append(character)
            } else {
                if number.count >= 3 { tokens.append(number.trimmingCharacters(in: CharacterSet(charactersIn: ".,-"))) }
                number = ""
            }
        }
        if number.count >= 3 { tokens.append(number.trimmingCharacters(in: CharacterSet(charactersIn: ".,-"))) }
        return tokens.filter { $0.count >= 3 }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "  n/a" : String(format: "%4.0f%%", Double(part) / Double(whole) * 100)
    }
}
