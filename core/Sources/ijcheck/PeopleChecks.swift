import Foundation
import InnerjoinCore

func peopleChecks() async {
    print("\nPeople · one person, however they're written")
    await check("a middle initial doesn't make a second person", middleInitial)
    await check("an initial resolves to the name it stands for", initials)
    await check("a short form resolves to the full name", shortForms)
    await check("two people sharing a surname are NOT merged", ambiguityRefused)
    await check("a bare surname is never enough on its own", bareSurname)
    await check("a shared email outranks how the name is spelled", identifierWins)
    await check("context breaks a tie that names alone can't", contextBreaksTies)
    await check("an unresolved mention is kept, not discarded", unresolvedIsKept)
    await check("identifiers are found however they're punctuated", identifierParsing)
    await check("resolving through the pipeline records the mention", mentionsRecorded)
}

private func person(_ id: Int64, _ name: String,
                    identifiers: Set<String> = [], context: Set<Int64> = []) -> Resolver.Candidate {
    Resolver.Candidate(entityID: id, name: name, kind: .person,
                       identifiers: identifiers, context: context)
}

private func middleInitial() async throws {
    // The bug that started all of this. Found in a real run of three documents: the owner
    // of the library was stored twice because one document wrote his middle initial.
    // The old rule tested whether the short name was a *prefix* of the long one, and a
    // middle initial is an insertion, not a truncation.
    let outcome = Resolver.resolve(surface: "Kian J. Feiz", kind: .person,
                                   among: [person(1, "Kian Feiz")])
    await expectEqual(outcome?.entityID, 1, "the same person, not a new one")
    await expectEqual(outcome?.how, .unambiguous, "resolved because only one Feiz fits")

    // And the other direction — the fuller name arriving first.
    let reverse = Resolver.resolve(surface: "Kian Feiz", kind: .person,
                                   among: [person(1, "Kian J. Feiz")])
    await expectEqual(reverse?.entityID, 1, "whichever order they arrive in")
}

private func initials() async throws {
    let outcome = Resolver.resolve(surface: "J. Ramirez", kind: .person,
                                   among: [person(1, "Joanna Ramirez")])
    await expectEqual(outcome?.entityID, 1, "J. Ramirez is Joanna Ramirez")

    // The surname has to match outright. An initial is weak evidence and can't carry
    // a mismatch on the part of the name that actually identifies someone.
    let wrongSurname = Resolver.resolve(surface: "J. Rodriguez", kind: .person,
                                        among: [person(1, "Joanna Ramirez")])
    await expect(wrongSurname == nil, "a different surname is a different person")

    // And the initial has to be the right letter.
    let wrongInitial = Resolver.resolve(surface: "M. Ramirez", kind: .person,
                                        among: [person(1, "Joanna Ramirez")])
    await expect(wrongInitial == nil, "M. Ramirez is not Joanna")
}

private func shortForms() async throws {
    await expectEqual(Resolver.matchKind("jo ramirez", "joanna ramirez"), .nickname,
                      "Jo is Joanna")
    await expectEqual(Resolver.matchKind("bob smith", "robert smith"), .nickname,
                      "Bob is Robert")
    await expect(!Resolver.couldBeTheSame("bob smith", "robert jones"),
                 "but only when the surname agrees")
}

private func ambiguityRefused() async throws {
    // The rule the whole design rests on. Most entity systems merge greedily and quietly
    // corrupt themselves — two people called Ramirez become one and nothing ever says so.
    // Refusing is the correct answer to an ambiguous question.
    let outcome = Resolver.resolve(surface: "J. Ramirez", kind: .person,
                                   among: [person(1, "Joanna Ramirez"),
                                           person(2, "Jose Ramirez")])
    await expect(outcome == nil, "two people it could be means it resolves to neither")

    // The same name is still exact — ambiguity only blocks the *inferring* rungs.
    let exact = Resolver.resolve(surface: "Joanna Ramirez", kind: .person,
                                 among: [person(1, "Joanna Ramirez"), person(2, "Jose Ramirez")])
    await expectEqual(exact?.entityID, 1, "an exact name is never ambiguous")
}

private func bareSurname() async throws {
    // "Feiz" could be any Feiz. Treating a lone surname as a match is how whole families
    // get merged into one person.
    let outcome = Resolver.resolve(surface: "Ramirez", kind: .person,
                                   among: [person(1, "Joanna Ramirez")])
    await expect(outcome == nil, "one word is not enough to identify a person")
    // "Ann" and "Anna" *are* related — the dataset says so and it's right. What keeps
    // them safe is that a nickname match alone never decides; it needs corroboration.
    await expectEqual(Resolver.matchKind("ann", "anna"), .nickname,
                      "related, but only as a nickname")
    await expect(Resolver.resolve(surface: "Ann", kind: .person,
                                  among: [person(1, "Anna")]) == nil,
                 "so a bare short form does not merge on its own")
}

private func identifierWins() async throws {
    // An email address is a globally unique key for a person, so it settles the question
    // regardless of how the name was typed. These were already being extracted and
    // thrown away.
    let outcome = Resolver.resolve(
        surface: "J.R.", kind: .person,
        identifiers: ["email:joanna@acme.com"],
        among: [person(1, "Joanna Ramirez", identifiers: ["email:joanna@acme.com"])])
    await expectEqual(outcome?.entityID, 1, "the address identifies her")
    await expectEqual(outcome?.how, .identifier, "and says that's why")

    // Two people sharing a document's identifiers is not a resolution.
    let shared = Resolver.resolve(
        surface: "J.R.", kind: .person,
        identifiers: ["email:info@acme.com"],
        among: [person(1, "Joanna Ramirez", identifiers: ["email:info@acme.com"]),
                person(2, "Jose Ramirez", identifiers: ["email:info@acme.com"])])
    await expect(shared == nil, "a shared inbox identifies nobody")
}

private func contextBreaksTies() async throws {
    // Names alone can't choose between two Ramirezes. Appearing beside someone the
    // candidate already knows is a second, independent signal.
    let outcome = Resolver.resolve(
        surface: "J. Ramirez", kind: .person,
        alongside: [42],
        among: [person(1, "Joanna Ramirez", context: [42]),
                person(2, "Jose Ramirez", context: [99])])
    await expectEqual(outcome?.entityID, 1, "the one who knows Acme is the one meant")
    await expectEqual(outcome?.how, .context, "recorded as context, not a guess")

    // If both know them, we're back to ambiguous.
    let both = Resolver.resolve(
        surface: "J. Ramirez", kind: .person,
        alongside: [42],
        among: [person(1, "Joanna Ramirez", context: [42]),
                person(2, "Jose Ramirez", context: [42])])
    await expect(both == nil, "context that fits both breaks no tie")
}

private func unresolvedIsKept() async throws {
    try await withWorkspace { store in
        let added = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(added.document.id, "id")

        let provider = ScriptedProvider(json: """
        {"title":"Lease","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"M. Osei","kind":"person","relation":"party_to"}]}
        """)
        _ = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        // The mention is evidence and is kept whatever happened to it, which is what
        // makes a wrong resolution fixable later without re-reading the document.
        let mentions = try store.mentions(of: try require(
            try store.entities().first(where: { $0.name == "M. Osei" })?.id, "the entity"))
        await expect(!mentions.isEmpty, "the mention is stored")
        let mention = try require(mentions.first, "a mention")
        await expectEqual(mention.surface, "M. Osei", "with the name exactly as written")
        await expectEqual(mention.documentID, documentID, "and the document it came from")
    }
}

private func identifierParsing() async throws {
    let found = Resolver.identifiers(in: """
        Contact Joanna at joanna@acme.com or (925) 407-5777.
        Alternate: +1 925-407-5777 · reception@acme.com
        """)
    await expect(found.contains("email:joanna@acme.com"), "an email is found")
    await expect(found.contains("email:reception@acme.com"), "and a second one")
    // Two spellings of one number must compare equal, or the strongest identity signal
    // available splits the person it was meant to join.
    await expectEqual(found.filter { $0.hasPrefix("phone:") }.count, 1,
                      "the same number written two ways is one identifier")
    await expect(found.contains("phone:9254075777"), "normalized to its last ten digits")

    // A year, an invoice number and a dollar amount are not phone numbers.
    let none = Resolver.identifiers(in: "Invoice A-2402 dated 2026-05-19 for 311.25")
    await expect(none.isEmpty, "numbers that aren't identifiers are left alone")
}

/// Writes a small markdown document containing exactly the text a check needs.
///
/// The entity gate refuses any name that doesn't appear in the document — which is right,
/// and which means a check about *resolving* names has to supply documents that genuinely
/// contain them rather than borrowing a fixture written for something else.
private func document(_ text: String, named name: String, in folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func mentionsRecorded() async throws {
    try await withWorkspace { store in
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ij-people-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let ingest = Ingest(store: store)
        let first = try await ingest.add(fileAt: try document(
            "# Tenancy\n\nSigned by Joanna Ramirez on 2026-01-04.\n",
            named: "tenancy.md", in: folder))
        let second = try await ingest.add(fileAt: try document(
            "# Receipt\n\nPayment received from J. Ramirez, 2026-02-01.\n",
            named: "receipt.md", in: folder))

        // The same person, written two ways across two documents.
        let full = ScriptedProvider(json: """
        {"title":"Lease","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"Joanna Ramirez","kind":"person","relation":"party_to"}]}
        """)
        let short = ScriptedProvider(json: """
        {"title":"Receipt","summary":"s","fields":[],"dates":[],
         "entities":[{"name":"J. Ramirez","kind":"person","relation":"party_to"}]}
        """)
        _ = try await Distill(store: store, provider: full)
            .understand(documentID: try require(first.document.id, "id"))
        _ = try await Distill(store: store, provider: short)
            .understand(documentID: try require(second.document.id, "id"))

        let people = try store.entities().filter { $0.kind == .person }
        await expectEqual(people.count, 1, "two spellings, one person")
        let joanna = try require(people.first, "her")
        await expect(joanna.aliases.contains("J. Ramirez"), "the other spelling is remembered")
        await expectEqual(try store.mentions(of: try require(joanna.id, "id")).count, 2,
                          "and both mentions point at her")
    }
}

/// The nickname table is now real data — 1,423 short forms from a public dataset —
/// which is a large increase in matching power and therefore in the chance of a wrong
/// merge. These pin the properties that make it safe.
func nicknameDataChecks() async {
    print("\nPeople · the nickname table")
    await check("real short forms are recognised", realNicknames)
    await check("two nicknames of one name are NOT each other", noSidewaysExpansion)
    await check("an ambiguous short form still can't merge two candidates", ambiguousShortForm)
}

private func realNicknames() async throws {
    // Ones my hand-written table never had.
    await expect(Nicknames.stands("peggy", for: "margaret"), "Peggy is Margaret")
    await expect(Nicknames.stands("hank", for: "henry"), "Hank is Henry")
    await expect(Nicknames.stands("jack", for: "john"), "Jack is John")
    await expect(Nicknames.stands("betsy", for: "elizabeth"), "Betsy is Elizabeth")
    await expect(Nicknames.formalNames["jo"]?.contains("joanna") == true, "Jo can be Joanna")
    // And the ambiguity the dataset actually shows, which a single-valued table hides.
    await expect((Nicknames.formalNames["jo"]?.count ?? 0) > 1,
                 "Jo stands for several names, and the table says so")
}

private func noSidewaysExpansion() async throws {
    // Bob and Bert are both short for Robert. Chaining through the formal name would
    // make them one person — the exact failure a bigger table makes more likely.
    // Both are listed as short forms of Robert, so the table relates them. Neither can
    // act on it alone — which is the protection, since the same table also wrongly
    // relates `bill` and `robert`.
    await expectEqual(Resolver.matchKind("bob chen", "bert chen"), .nickname,
                      "the table relates them")
    await expect(Resolver.resolve(surface: "Bert Chen", kind: .person,
                                  among: [person(1, "Bob Chen")]) == nil,
                 "but a nickname resemblance alone never merges two people")
    await expectEqual(Resolver.resolve(surface: "Bob Chen", kind: .person,
                                       alongside: [7],
                                       among: [person(1, "Robert Chen", context: [7])])?.entityID, 1,
                      "with corroboration it resolves")
    // Jose is not a short form of anything, so it can never reach Joanna this way.
    await expect(!Resolver.couldBeTheSame("jo ramirez", "jose ramirez"),
                 "Jo does not become Jose")
}

private func ambiguousShortForm() async throws {
    // "Jo" fits Joanna and Joan alike. With both in the library the honest answer is
    // neither, and the uniqueness rule is what delivers it.
    let both = Resolver.resolve(surface: "Jo Ramirez", kind: .person,
                                among: [person(1, "Joanna Ramirez"), person(2, "Joan Ramirez")])
    await expect(both == nil, "an ambiguous short form resolves to nobody")

    let corroborated = Resolver.resolve(surface: "Jo Ramirez", kind: .person,
                                        alongside: [9],
                                        among: [person(1, "Joanna Ramirez", context: [9])])
    await expectEqual(corroborated?.entityID, 1, "but resolves once something corroborates it")
}

/// Typo tolerance — the one thing the published record-linkage tools had that the ladder
/// didn't. Found in a real dataset: "Marcus Web" and "Marcus Webb" were two people.
func typoChecks() async {
    print("\nPeople · misspellings")
    await check("one misspelt word is recognised", typoRecognised)
    await check("two different names are not a typo of each other", typoRefused)
    await check("a misspelling alone never merges anyone", typoNeedsCorroboration)
}

private func typoRecognised() async throws {
    await expectEqual(Resolver.matchKind("marcus web", "marcus webb"), .typo,
                      "a dropped letter")
    await expectEqual(Resolver.matchKind("maria gonzales", "maria gonzalez"), .typo,
                      "a substituted letter")
    await expectEqual(Resolver.editDistance("webb", "web"), 1, "distance is measured, not guessed")
}

private func typoRefused() async throws {
    // One edit apart and genuinely two people. Graded similarity does see a resemblance
    // here — Jaro-Winkler scores them 0.93 — and that is why similarity may only ever
    // propose. What protects Jon from Jan is the corroboration neither of them has.
    await expect(Resolver.matchKind("jon smith", "jan smith") != .typo,
                 "a three-letter given name differing by one letter is not a typo")
    await expect(Resolver.resolve(surface: "Jan Smith", kind: .person,
                                  among: [person(1, "Jon Smith")]) == nil,
                 "and resemblance alone merges nobody")
    await expect(Resolver.matchKind("marcus web", "marcus chen") == nil,
                 "a different surname is not a misspelling")
    await expect(Resolver.matchKind("marc webb", "marcus webb") != .typo,
                 "two edits is not one")
}

private func typoNeedsCorroboration() async throws {
    let alone = Resolver.resolve(surface: "Marcus Web", kind: .person,
                                 among: [person(1, "Marcus Webb")])
    await expect(alone == nil, "a misspelling on its own resolves to nobody")

    let corroborated = Resolver.resolve(surface: "Marcus Web", kind: .person,
                                        alongside: [5],
                                        among: [person(1, "Marcus Webb", context: [5])])
    await expectEqual(corroborated?.entityID, 1, "with corroboration it resolves")

    let byEmail = Resolver.resolve(surface: "Maria Gonzales", kind: .person,
                                   identifiers: ["email:m@example.com"],
                                   among: [person(1, "Maria Gonzalez",
                                                  identifiers: ["email:m@example.com"])])
    await expectEqual(byEmail?.entityID, 1, "and an address settles it outright")
}

/// Written forms from a real passenger register — 891 names, 8 titles, 143 with a maiden
/// name in brackets. None of these shapes existed in any corpus I wrote myself.
func writtenFormChecks() async {
    print("\nPeople · how registers write names")
    await check("surname-first with a title resolves to the ordinary form", invertedNames)
    await check("an organization's legal form is not a given name", notPeople)
}

private func invertedNames() async throws {
    // "Braund, Mr. Owen Harris" against "Owen Harris Braund" — the same passenger, and
    // untouched the two share not one word in the same position.
    await expectEqual(Resolver.matchKind("Braund, Mr. Owen Harris", "Owen Harris Braund"),
                      .subsequence, "inverted order and a title are undone")
    await expectEqual(Resolver.matchKind("Heikkinen, Miss. Laina", "Laina Heikkinen"),
                      .subsequence, "and for a shorter name")
    // The bracketed name is a second name for the same person, not part of this one.
    await expectEqual(Entity.canonicalPersonForm("Futrelle, Mrs. Jacques Heath (Lily May Peel)"),
                      "Jacques Heath Futrelle", "a bracketed maiden name is set aside")
    await expectEqual(Entity.canonicalPersonForm("Dr. Alice Chen"), "Alice Chen",
                      "a title in the ordinary order goes too")
}

private func notPeople() async throws {
    // The guard that keeps this away from everything that isn't a person. Inverting
    // "Alcon Laboratories, Inc." produces "Inc Alcon Laboratories", which then matches
    // nothing — the checks caught exactly this.
    await expectEqual(Entity.canonicalPersonForm("Alcon Laboratories, Inc."),
                      "Alcon Laboratories, Inc.", "a legal form is left where it is")
    await expectEqual(Entity.canonicalPersonForm("PG&E, Inc."), "PG&E, Inc.",
                      "even after a one-word name")
    await expectEqual(Entity.canonicalPersonForm("1247 Fillmore St, San Francisco"),
                      "1247 Fillmore St, San Francisco", "an address is not an inverted name")
    await expectEqual(Entity.normalize("Alcon Laboratories, Inc."),
                      Entity.normalize("Alcon Laboratories"),
                      "and the stored key is unchanged by any of this")
}

func discriminatorChecks() async {
    print("\nPeople · the part of a name that tells two people apart")
    await check("a generation or reign is not a misspelling", generationsStayApart)
    await check("numbers that contradict separate; numbers that add do not", numbersDiscriminate)
    await check("middle initials that disagree don't decide alone", initialsMustAgree)
    await check("a shared given name doesn't carry a match on its own", sharedWordsDontCarry)
}

private func generationsStayApart() async throws {
    // The merge a family archive can't afford. Every other rung reads "III" as "II" with
    // a slip of the finger.
    await expectNil(Resolver.matchKind("Robert Feiz Jr", "Robert Feiz Sr"),
                    "a junior is not a senior")
    await expectNil(Resolver.matchKind("Gordian II", "Gordian III"),
                    "nor is one emperor the next")
    // Only when both names say so. A name that simply doesn't record a generation isn't
    // contradicting one that does.
    await expectEqual(Resolver.matchKind("Robert Feiz", "Robert Feiz Jr"), .subsequence,
                      "silence is not disagreement")
}

private func numbersDiscriminate() async throws {
    // Japanese writes the same distinction with digits and no spaces to find them between.
    await expectNil(Resolver.matchKind("ゴルディアヌス2世", "ゴルディアヌス3世"),
                    "a regnal number in any script")
    // Compared where both names speak. An apartment elaborates on an address; it does
    // not contradict it.
    await expectEqual(Resolver.numbers(in: "1247 fillmore st apt 4"), ["1247", "4"],
                      "digit runs are read in order")
    await expectNotNil(Resolver.matchKind("1247 Fillmore St", "1247 Fillmore St, Apt 4"),
                       "adding a number is not contradicting one")
}

private func initialsMustAgree() async throws {
    // A literal subsequence, a father and a son. Measured on real names, where it merged.
    await expect(Resolver.initialsDisagree("George W. Bush", "George H. W. Bush"),
                 "two names that both state initials, differently")
    await expect(!Resolver.initialsDisagree("Kian Feiz", "Kian J. Feiz"),
                 "one name stating nothing disagrees with nothing")
}

private func sharedWordsDontCarry() async throws {
    // Jaro-Winkler's prefix bonus rewards the shared word hardest, which is the word that
    // identifies neither of them. Both of these merged before the leftover words had to
    // agree too.
    await expectNil(Resolver.matchKind("Mohammad Hatta", "Mohammad Ahsan"),
                    "a common given name is not evidence")
    await expectNil(Resolver.matchKind("Nguyễn Chí Thiện", "Nguyễn Hải Thần"),
                    "nor a surname two-fifths of a country carries")
    // What the rungs are actually for still passes. One edit is a typo, which is caught
    // before similarity is ever consulted; two edits across two words is what falls
    // through to graded similarity, and it has to survive the floor.
    await expectEqual(Resolver.matchKind("Peter Smith", "Peter Smyth"), .typo,
                      "a single-letter surname slip is a typo")
    // The floor itself, measured on the case it must not block: a misspelt surname scores
    // 0.89 against its correct spelling, which is why the floor sits below the threshold
    // that governs the whole name.
    await expect(Resolver.distinguishingSimilarity(["peter", "smith"], ["peter", "smyth"])
                 >= Resolver.distinguishingFloor, "a misspelt surname clears the floor")
    await expect(Resolver.distinguishingSimilarity(["david", "cameron"], ["david", "paterson"])
                 < Resolver.distinguishingFloor, "two unrelated surnames do not")
    // The same words in another order is one name written two ways.
    await expectEqual(Resolver.distinguishingSimilarity(["dung", "nguyen"], ["nguyen", "dung"]), 1.0,
                      "word order is a convention, not a difference")
}
