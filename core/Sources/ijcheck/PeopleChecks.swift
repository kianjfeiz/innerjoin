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
    await expect(Resolver.couldBeTheSame("jo ramirez", "joanna ramirez"),
                 "Jo is Joanna")
    await expect(Resolver.couldBeTheSame("bob smith", "robert smith"),
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
    await expect(!Resolver.couldBeTheSame("ann", "anna"),
                 "and near-identical single words stay apart")
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
