import Foundation
import DunesCore

/// What the app agrees to answer.
///
/// The rules themselves are a matter of taste and live in `Policy` to be edited. What is
/// checked here is the machinery around them, because that is what makes editing them
/// safe: that a rule which outranks the library really does skip retrieval and the model,
/// that a rule which doesn't can never come between a person and their own documents, and
/// that "hi" stops being a greeting the moment a real question is attached to it.
func policyChecks() async {
    print("\nPolicy · what the app will answer")
    await check("a greeting is answered as a greeting, for free", greetingIsFree)
    await check("a greeting with a question attached is a question", greetingPlusQuestion)
    await check("a stretched greeting still reads as one", stretchedGreeting)
    await check("real doubled letters survive the collapse", doubledLettersSurvive)
    await check("a declined subject explains itself better than a miss", codingIsDeclined)
    await check("a rule that doesn't outrank never blocks a real answer", libraryWins)
    await check("an ordinary miss still gets the library's own refusal", ordinaryMiss)
}

// MARK: -

/// The case from the screenshot: "hiiiiii" used to be run through retrieval, miss, and
/// come back as "nothing in your 10 files mentions that" — which is true, and reads as a
/// machine that didn't understand it was being greeted.
private func greetingIsFree() async throws {
    try await withLibrary { store, _, _ in
        let provider = CountingProvider(json: #"{"answered":true,"answer":"x","citations":[]}"#)
        let answer = try await Ask(store: store, provider: provider).answer("hiiiiii")

        await expect(!answer.answered, "a greeting is not an answer about the library")
        await expectEqual(provider.calls, 0, "and costs no model call")
        await expect(answer.text.hasPrefix("Hello"), "it is greeted back")
        await expect(!answer.text.contains("Nothing in your"),
                     "and is not told its files are missing something")
    }
}

/// The reason smalltalk matches on the whole question and nothing less. A greeting in
/// front of a real question is politeness, not the subject.
private func greetingPlusQuestion() async throws {
    let rule = Policy.refusalBeforeRetrieval("hi, what does my lease say?")
    await expect(rule == nil, "a question with a greeting on the front is still a question")

    await expect(Policy.refusalBeforeRetrieval("hey there")?.name == "smalltalk",
                 "while filler after a greeting leaves it a greeting")
}

private func stretchedGreeting() async throws {
    for typed in ["hiiiiii", "heyyyyy", "hellooooo", "HI", "hi!!!"] {
        await expect(Policy.refusalBeforeRetrieval(typed)?.name == "smalltalk",
                     "\"\(typed)\" is a greeting")
    }
}

/// The collapse only fires at three, so ordinary English is untouched — otherwise
/// "cheers" would become "chers" and stop matching its own trigger.
private func doubledLettersSurvive() async throws {
    await expectEqual(Policy.collapse("cheers"), "cheers", "a real double is left alone")
    await expectEqual(Policy.collapse("coffee"), "coffee", "and another")
    await expectEqual(Policy.collapse("hiiiiii"), "hi", "a triple or longer collapses to one")
    await expect(Policy.refusalBeforeRetrieval("cheers")?.name == "smalltalk",
                 "so a doubled word still matches its trigger")
}

/// A declined subject replaces the generic miss, and says what the app is for rather
/// than only what it won't do.
private func codingIsDeclined() async throws {
    try await withLibrary { store, _, _ in
        let provider = CountingProvider(json: #"{"answered":true,"answer":"x","citations":[]}"#)
        let answer = try await Ask(store: store, provider: provider)
            .answer("write a function that reverses a linked list")

        await expect(!answer.answered, "it is declined")
        await expectEqual(provider.calls, 0, "without a model call")
        await expect(answer.text.contains("coding assistant"), "and says why")
        await expect(answer.text.contains("library"), "and what it does instead")
    }
}

/// The load-bearing default. A rule that doesn't outrank the library is only ever
/// consulted after retrieval came back empty, so it cannot hide a document from the
/// person who filed it — whatever words the question happens to contain.
private func libraryWins() async throws {
    let question = "what does my lease say about the sql query fee"
    await expect(Policy.refusalBeforeRetrieval(question) == nil,
                 "a non-outranking rule never fires before retrieval")
    await expect(Policy.refusalAfterEmptyRetrieval(question)?.name == "coding",
                 "though it is there to speak if retrieval finds nothing")

    try await withLibrary { store, leaseID, _ in
        let provider = CountingProvider(json: """
        {"answered":true,"answer":"The rent is 2,400.","citations":[{"cite":"d\(leaseID):e0"}]}
        """)
        let answer = try await Ask(store: store, provider: provider)
            .answer("what is the rent in the lease")
        await expectEqual(provider.calls, 1, "a real question still reaches the model")
        await expect(answer.answered, "and is answered from the library")
    }
}

/// Nothing about the policy changes the ordinary case: a miss that matches no rule still
/// gets the refusal that names what the library does hold.
private func ordinaryMiss() async throws {
    try await withLibrary { store, _, _ in
        let provider = CountingProvider(json: #"{"answered":true,"answer":"x","citations":[]}"#)
        let answer = try await Ask(store: store, provider: provider)
            .answer("what did the submarine cost")
        await expect(answer.text.contains("Nothing in your"),
                     "an unrecognised miss is still answered by the library itself")
    }
}
