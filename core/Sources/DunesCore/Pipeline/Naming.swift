import Foundation

/// Gives a document a name that says what it is.
///
/// Files arrive called `scan_0001.pdf`, `document (3).docx`, `KianJFResume.pdf` — names
/// that survived a scanner, a downloads folder and a decade of habit, and that tell you
/// nothing when you're looking for something later. Once a document has been understood
/// dunes already knows its subject, its date and who it involves: everything a
/// filing clerk would have written on the folder.
///
/// No model call. Every part of the name is already in the record, so naming is a pure
/// function of what was understood — free, instant, and the same answer every time.
///
/// Two things it deliberately does not do. It never overwrites the name the file arrived
/// with, because that name is provenance and someone will eventually go looking for it.
/// And it never renames anything on disk: the original is the user's, and the vault copy
/// is addressed by content. A better name is a better label, not a better path.
public enum Naming {

    /// Longest name we'll produce, before the extension. APFS allows 255 bytes; staying
    /// well short keeps a name readable in a sidebar and leaves room for the extension
    /// and a disambiguating suffix.
    static let maximumStemCharacters = 96
    static let maximumPartyCharacters = 44

    /// One entity a record is linked to, with the relation that links them.
    public struct Party: Sendable, Equatable {
        public let name: String
        public let kind: Entity.Kind
        public let relation: String
        public let confidence: Double

        public init(name: String, kind: Entity.Kind, relation: String, confidence: Double = 1) {
            self.name = name
            self.kind = kind
            self.relation = relation
            self.confidence = confidence
        }
    }

    /// The name this document should carry, or nil when nothing better than the name it
    /// arrived with can be built.
    ///
    /// Shape: `2026-06-15 Travel insurance certificate — ACE.pdf`. Each part is dropped
    /// when it's missing or already implied, so an undated résumé becomes
    /// `Resume — Kian Feiz.pdf` rather than carrying an invented date.
    public static func propose(record: Record, parties: [Party], arrivedAs arrivalName: String) -> String? {
        let suffix = (arrivalName as NSString).pathExtension
        let arrivalStem = (arrivalName as NSString).deletingPathExtension

        let subject = self.subject(of: record, extension: suffix)
        let party = self.party(among: parties, avoiding: subject ?? arrivalStem)
        let stamp = record.happenedOn.flatMap(self.stamp)

        // A name is only worth changing if we learned something the file didn't already
        // say. With no subject, no date and no party there is nothing to add.
        guard subject != nil || stamp != nil || party != nil else { return nil }

        let head = subject ?? sanitize(arrivalStem)
        guard !head.isEmpty else { return nil }

        var stem = head
        if let party { stem += " — \(party)" }
        if let stamp { stem = "\(stamp) \(stem)" }
        stem = shorten(stem, head: head, stamp: stamp, party: party)

        let named = suffix.isEmpty ? stem : "\(stem).\(suffix)"
        // Proposing the name it already has is the same as proposing nothing.
        return named.compare(arrivalName, options: [.caseInsensitive]) == .orderedSame ? nil : named
    }

    // MARK: - The subject

    /// What the document is about, in the words the record uses.
    static func subject(of record: Record, extension suffix: String) -> String? {
        // The holding category is where a document goes when the graph *couldn't* place
        // it. Naming a file "Everything else.pdf" would state that failure as a fact.
        let category = record.category == Organize.holdingCategory ? nil : record.category
        for candidate in [record.title, record.kind, category.map(singular)] {
            guard let candidate else { continue }
            let tidied = tidy(candidate, extension: suffix)
            if informative(tidied) { return tidied }
        }
        return nil
    }

    static func tidy(_ text: String, extension suffix: String) -> String {
        var out = sanitize(text.replacingOccurrences(of: "_", with: " "))
        // Models often echo the filename back, extension and all.
        if !suffix.isEmpty, out.lowercased().hasSuffix(".\(suffix.lowercased())") {
            out = String(out.dropLast(suffix.count + 1))
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'“”"))
        return capitalizeFirst(unshout(out))
    }

    /// A subject taken from `kind` or `category` arrives lowercase ("lease"), and a name
    /// starting in lowercase looks like a mistake. Only lifts a first word that is
    /// entirely lowercase, so "iPhone receipt" is left alone.
    static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.split(separator: " ").first, first.count > 1,
              first == first.lowercased()
        else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Titles lifted from a heading arrive shouting: "STEPS BEFORE ARRIVING". A filename
    /// in capitals is unpleasant to read, so long all-caps titles come down to sentence
    /// case — leaving short tokens alone, since those are usually acronyms (ACE, UC3M).
    public static func unshout(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 2,
              text == text.uppercased(),
              text.rangeOfCharacter(from: .lowercaseLetters) == nil,
              text.rangeOfCharacter(from: .uppercaseLetters) != nil
        else { return text }

        return words.enumerated().map { position, word in
            if word.count <= 4 { return word }               // ACE, UC3M, EPS, PDF
            let lowered = word.lowercased()
            guard position == 0 else { return lowered }
            return lowered.prefix(1).uppercased() + lowered.dropFirst()
        }.joined(separator: " ")
    }

    /// Whether a candidate subject actually distinguishes this document from any other.
    static func informative(_ text: String) -> Bool {
        let trimmed = text.trimmed
        guard trimmed.count >= 4 else { return false }
        // A name made of digits is a serial number, not a subject.
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        return !emptyWords.contains(trimmed.lowercased())
    }

    /// What a model says when it has nothing to say.
    private static let emptyWords: Set<String> = [
        "untitled", "untitled document", "document", "documento", "file", "scan",
        "scanned document", "image", "photo", "attachment", "unknown", "no title",
        "page 1", "text", "pdf document",
    ]

    /// "Invoices" → "Invoice". Categories are named in the plural; a single document is
    /// one of them.
    static func singular(_ category: String) -> String {
        let word = category.trimmed
        guard word.count > 3 else { return word }
        let lower = word.lowercased()
        if lower.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        for ending in ["sses", "ches", "shes", "xes"] where lower.hasSuffix(ending) {
            return String(word.dropLast(2))
        }
        if lower.hasSuffix("s"), !lower.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    // MARK: - The other party

    /// Who the document is with. One name only: a filename listing every party is a
    /// paragraph, not a label.
    static func party(among parties: [Party], avoiding subject: String) -> String? {
        let subjectKey = Entity.normalize(subject)
        let ranked = parties
            .filter { kindRank($0.kind) != nil }
            .filter { candidate in
                let key = Entity.normalize(candidate.name)
                guard !key.isEmpty else { return false }
                // Saying it twice adds nothing: "Resume — Kian Feiz" is right,
                // "Kian Feiz Resume — Kian Feiz" is noise.
                return !subjectKey.contains(key) && !key.contains(subjectKey)
            }
            .sorted { left, right in
                // Who before where. A real run produced "Notice of Rent Adjustment —
                // 1247 Fillmore St, Apt 4, San Francisco, CA": the address is a party to
                // the notice, but nobody calls a document by its address when there's a
                // landlord's name available.
                let leftKind = kindRank(left.kind) ?? 9, rightKind = kindRank(right.kind) ?? 9
                if leftKind != rightKind { return leftKind < rightKind }
                let leftRelation = relationRank(left.relation), rightRelation = relationRank(right.relation)
                if leftRelation != rightRelation { return leftRelation < rightRelation }
                if left.confidence != right.confidence { return left.confidence > right.confidence }
                return left.name < right.name   // ties broken by name, so the answer is stable
            }

        guard let best = ranked.first else { return nil }
        return truncate(sanitize(best.name), to: maximumPartyCharacters)
    }

    /// Which relation makes something *the* other party. `mentions` is last on purpose —
    /// a passing mention is not who a document is with.
    static func relationRank(_ relation: String) -> Int {
        let order = ["issued_by", "employed_by", "party_to", "paid_to", "governs", "covers", "owns"]
        return order.firstIndex(of: relation) ?? order.count
    }

    /// Places, products and account numbers can be a document's party, but only after
    /// the people and organizations. `other` never is — it's the kind we couldn't name.
    static func kindRank(_ kind: Entity.Kind) -> Int? {
        switch kind {
        case .org:     return 0
        // A document about a project is best named after the project — "Status report —
        // Apollo Migration" beats naming it after whoever happened to write it.
        case .project: return 1
        case .person:  return 2
        case .place:   return 3
        case .product: return 4
        case .account, .other: return nil
        }
    }

    // MARK: - Formatting

    /// The document's own date, not the day it was added.
    ///
    /// Deliberately day-precision: a document stating only "2026" parses to the first of
    /// January, and a name reading `2026-01-01` claims a day the document never gave.
    /// Documents that only state a year are usually undated things — handbooks, résumés —
    /// where extraction leaves the date empty anyway, so in practice this stays honest.
    static func stamp(_ date: Date) -> String? {
        guard Dates.isPlausible(date) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Makes a string safe to be a filename, whatever an API will let you write.
    ///
    /// `/` is the path separator on disk and `:` is the one the Finder shows, so both are
    /// wrong in a name regardless of which layer accepts it. A leading dot hides the
    /// file; trailing dots and spaces get silently trimmed by some tools and kept by
    /// others, which is how two names that look identical stop matching.
    public static func sanitize(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        out = out.components(separatedBy: .controlCharacters).joined(separator: " ")
        out = out.components(separatedBy: .newlines).joined(separator: " ")
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// Brings an over-long name down to size by shortening the subject, which is the
    /// part that can lose a clause and still be recognizable. The date and the party are
    /// short and load-bearing, so they stay whole.
    static func shorten(_ stem: String, head: String, stamp: String?, party: String?) -> String {
        guard stem.count > maximumStemCharacters else { return stem }
        let fixed = (stamp.map { $0.count + 1 } ?? 0) + (party.map { $0.count + 3 } ?? 0)
        let room = max(12, maximumStemCharacters - fixed)

        var rebuilt = truncate(head, to: room)
        if let party { rebuilt += " — \(party)" }
        if let stamp { rebuilt = "\(stamp) \(rebuilt)" }
        return rebuilt
    }

    /// Cuts at a word boundary where there is one, so a name ends on a word rather than
    /// mid-syllable.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit))
        let cut = clipped.lastIndex(of: " ").map { clipped[..<$0] } ?? Substring(clipped)
        return String(cut).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-—"))
    }

    /// Keeps a name unique inside the library.
    ///
    /// Two genuinely different files can deserve the same name — two statements the model
    /// titles identically. Numbering them is honest; silently showing one name twice
    /// isn't. Suffixes go in document order, so an existing name never moves.
    public static func unique(_ name: String, among taken: Set<String>) -> String {
        let folded = Set(taken.map { $0.lowercased() })
        return unique(name) { folded.contains($0.lowercased()) }
    }

    /// The same rule where "taken" means something other than a set — a folder on disk,
    /// for instance.
    public static func unique(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }

        let suffix = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for counter in 2...9_999 {
            let candidate = suffix.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(suffix)"
            if !isTaken(candidate) { return candidate }
        }
        return name   // ten thousand of the same name is someone else's problem
    }
}

/// Writes derived names into the library, and copies files out under them.
public struct Namer: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    /// Names one document from what was understood about it. Returns the name it now
    /// carries, or nil if it kept the one it arrived with.
    @discardableResult
    public func name(documentID: Int64) async throws -> String? {
        guard let document = try store.document(id: documentID),
              let record = try store.record(ofDocument: documentID),
              let recordID = record.id
        else { return nil }

        let parties = try store.parties(ofRecord: recordID)
        guard let proposed = Naming.propose(record: record, parties: parties,
                                            arrivedAs: document.name)
        else {
            // Understanding may have got worse — a re-read that lost the title. Clear a
            // stale name rather than leaving a label the record no longer supports.
            if document.displayName != nil { try await write(nil, to: documentID) }
            return nil
        }

        let taken = try store.displayNames(excluding: documentID)
        let final = Naming.unique(proposed, among: taken)
        guard final != document.displayName else { return final }
        try await write(final, to: documentID)
        return final
    }

    /// Re-derives every name in the library, oldest document first.
    ///
    /// Order matters only for collisions: numbering in document order means adding a
    /// second "Invoice" never renames the first one.
    @discardableResult
    public func nameAll() async throws -> Int {
        var changed = 0
        for document in try store.allDocuments() {
            guard let id = document.id else { continue }
            let before = document.displayName
            let after = try await name(documentID: id)
            if before != after { changed += 1 }
        }
        return changed
    }

    /// Copies the library out under its derived names — the one place a name reaches the
    /// filesystem, and it makes copies, so nothing the user owns is touched.
    public struct Exported: Sendable {
        public let from: String
        public let to: String
    }

    public func export(to folder: URL) throws -> [Exported] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: Set<String> = []
        var out: [Exported] = []

        for document in try store.allDocuments() {
            let source = store.vault.url(for: document.vaultPath)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            // Whatever is already in the destination counts as taken too, so exporting
            // twice into the same folder adds rather than clobbers.
            let target = Naming.unique(document.label) { candidate in
                written.contains(candidate.lowercased())
                    || FileManager.default.fileExists(
                        atPath: folder.appendingPathComponent(candidate).path)
            }
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(target))
            written.insert(target.lowercased())
            out.append(Exported(from: document.name, to: target))
        }
        return out
    }

    private func write(_ name: String?, to documentID: Int64) async throws {
        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE document SET displayName = ? WHERE id = ?",
                           arguments: [name, documentID])
        }
    }
}
