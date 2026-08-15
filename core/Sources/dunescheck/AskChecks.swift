import Foundation
import DunesCore

func askChecks() async {
    print("\nAsk · reasoning over the library")
    await check("a question in words retrieves the right document", retrievalFromAQuestion)
    await check("question words don't sink the query", questionWords)
    await check("an answer's citations resolve to a page and a box", citationsResolve)
    await check("an invented citation is dropped, not shown", inventedCitationDropped)
    await check("a citation to a document not consulted is refused", crossDocumentCitation)
    await check("a miss still reaches the model, empty-handed", nothingMatches)
    await check("an empty library is answered, not refused", nothingToSearch)
    await check("a confident answer with no words is not passed off as one", emptyAnswer)
    await check("the same citation twice is shown once", duplicateCitations)
}

/// Records a call so a check can prove the model was never asked.
final class CountingProvider: ModelProvider, @unchecked Sendable {
    let json: String
    private(set) var calls = 0
    /// What the model was actually shown. Checking that a miss travels *empty* matters
    /// more than checking it travels at all.
    private(set) var lastUser = ""
    init(json: String) { self.json = json }
    var label: String { "Counting" }
    func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data {
        calls += 1
        lastUser = user
        return Data(json.utf8)
    }
}

/// Two documents in a library, both understood, so retrieval has something to choose
/// between and citations have somewhere to land.
func withLibrary(_ body: (Store, Int64, Int64) async throws -> Void) async throws {
    try await withWorkspace { store in
        let ingest = Ingest(store: store)
        let lease = try await ingest.add(fileAt: try fixture("lease.pdf"))
        let invoice = try await ingest.add(fileAt: try fixture("receipt.png"))
        let leaseID = try require(lease.document.id, "lease id")
        let invoiceID = try require(invoice.document.id, "second document id")
        let distill = Distill(store: store, provider: MockProvider())
        _ = try await distill.understand(documentID: leaseID)
        _ = try await distill.understand(documentID: invoiceID)
        try await body(store, leaseID, invoiceID)
    }
}

private func retrievalFromAQuestion() async throws {
    try await withLibrary { store, leaseID, _ in
        // Retrieval runs before any model, so this part of answering costs nothing and
        // works with no key.
        let hits = try store.retrieve("what does the lease say about the deposit?")
        await expect(!hits.isEmpty, "a question in plain words finds something")
        await expect(hits.contains { $0.document.id == leaseID },
                     "and the document it's asking about is among them")
    }
}

private func questionWords() async throws {
    // The failure this guards against: `find` demands every token match, so "how much is
    // my rent?" matches nothing at all — the document contains "rent" and none of the
    // rest. Retrieval has to throw away the scaffolding of the question first.
    let words = Store.contentWords(of: "How much is my rent?")
    await expectEqual(words, ["rent"], "only the word a document might contain survives")
    await expect(Store.contentWords(of: "when does it expire").contains("expire"),
                 "the verb that carries the meaning is kept")
    await expect(Store.contentWords(of: "who is the landlord") == ["landlord"],
                 "and the noun being asked about")

    try await withLibrary { store, leaseID, _ in
        let hits = try store.retrieve("how much is my rent?")
        await expect(hits.contains { $0.document.id == leaseID },
                     "so the question reaches the lease")
    }
}

private func citationsResolve() async throws {
    try await withLibrary { store, leaseID, _ in
        let provider = CountingProvider(json: """
        {"answered":true,"answer":"The rent is stated in the lease.",
         "citations":[{"document":"d\(leaseID)","element":"e0"}]}
        """)
        let answer = try await Ask(store: store, provider: provider).answer("what is the rent?")

        await expect(answer.answered, "the answer stands")
        await expectEqual(answer.citations.count, 1, "one citation survives")
        let citation = try require(answer.citations.first, "the citation")
        await expectEqual(citation.documentID, leaseID, "pointing at the right document")
        await expect(citation.page != nil, "resolved to a page")
        await expect(citation.box != nil, "and to a box on that page")
        await expect(!citation.quote.isEmpty, "carrying the text that's actually there")
        await expectEqual(answer.invented, 0, "and nothing was invented")
    }
}

private func inventedCitationDropped() async throws {
    try await withLibrary { store, leaseID, _ in
        // "e9999" is not an element of that document. Shown to a person it would open
        // nothing, which is the one failure that destroys trust in the whole app.
        let provider = CountingProvider(json: """
        {"answered":true,"answer":"The rent is $2,400.",
         "citations":[{"document":"d\(leaseID)","element":"e0"},
                      {"document":"d\(leaseID)","element":"e9999"}]}
        """)
        let answer = try await Ask(store: store, provider: provider).answer("what is the rent?")
        await expectEqual(answer.citations.count, 1, "only the real citation is shown")
        await expectEqual(answer.invented, 1, "and the invented one is counted, not hidden")
    }
}

private func crossDocumentCitation() async throws {
    try await withLibrary { store, leaseID, invoiceID in
        // A real anchor, but on a document retrieval didn't put in front of the model —
        // so the model can't have read it, and the citation is a guess.
        let provider = CountingProvider(json: """
        {"answered":true,"answer":"Cited from somewhere it never saw.",
         "citations":[{"document":"d99999","element":"e0"}]}
        """)
        let answer = try await Ask(store: store, provider: provider, breadth: 1)
            .answer("what is the rent?")
        await expectEqual(answer.citations.count, 0, "a citation to an unseen document is refused")
        await expectEqual(answer.invented, 1, "and counted")
        _ = invoiceID
    }
}

private func nothingMatches() async throws {
    try await withLibrary { store, leaseID, _ in
        // The model is told to cite, and offered a document that was never retrieved.
        let provider = CountingProvider(
            json: #"{"answered":true,"answer":"Not in your files, but submarines are "#
                + #"expensive.","citations":[{"cite":"d"# + "\(leaseID)" + #":e0"}]}"#)
        let answer = try await Ask(store: store, provider: provider)
            .answer("what did the submarine cost")

        await expectEqual(provider.calls, 1,
                          "a question retrieval can't help with is still a question")
        await expect(provider.lastUser.contains("No material"),
                     "and the model is told it has nothing to work from")
        await expect(!provider.lastUser.contains("[d"),
                     "with no document handed to it")

        // The safety property. Nothing was retrieved, so nothing can be cited — a
        // citation proposed anyway points at a document the model never saw.
        await expect(answer.citations.isEmpty, "a citation invented over nothing is dropped")
        await expect(!answer.answered,
                     "and `answered` stays false, because the library answered nothing")
        await expect(!answer.text.isEmpty, "while the person still gets a reply")
    }
}

/// An empty library is a library with nothing in it, not a broken app. It answers, and
/// the model is told there is nothing there so it can say what to do about it.
private func nothingToSearch() async throws {
    try await withWorkspace { store in
        let provider = CountingProvider(json: #"{"answered":false,"answer":"Nothing in there yet.","citations":[]}"#)
        let answer = try await Ask(store: store, provider: provider).answer("anything at all")
        await expectEqual(provider.calls, 1, "an empty library is still answered")
        await expect(provider.lastUser.contains("nothing at all yet"),
                     "and the model is told the library is empty")
        await expect(provider.lastUser.contains("dunes add"),
                     "so it can say how to fill it")
        await expect(!answer.answered, "nothing was answered from the library")
    }
}

private func emptyAnswer() async throws {
    try await withLibrary { store, leaseID, _ in
        // A model can claim success and return nothing. Presenting that as an answer
        // would show a person an empty confident box.
        let provider = CountingProvider(json: """
        {"answered":true,"answer":"   ","citations":[{"document":"d\(leaseID)","element":"e0"}]}
        """)
        let answer = try await Ask(store: store, provider: provider).answer("what is the rent?")
        await expect(!answer.answered, "an empty answer is not an answer")
    }
}

private func duplicateCitations() async throws {
    try await withLibrary { store, leaseID, _ in
        let provider = CountingProvider(json: """
        {"answered":true,"answer":"Stated twice.",
         "citations":[{"document":"d\(leaseID)","element":"e0"},
                      {"document":"d\(leaseID)","element":"e0"}]}
        """)
        let answer = try await Ask(store: store, provider: provider).answer("what is the rent?")
        await expectEqual(answer.citations.count, 1, "the same anchor is listed once")
        await expectEqual(answer.invented, 0, "and a repeat isn't mistaken for an invention")
    }
}
