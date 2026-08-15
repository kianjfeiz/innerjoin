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
    await check("generation priced by the yard is refused, for free", bulkIsDeclined)
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
        await expect(answer.text.hasPrefix("Hey"), "it is greeted back")
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
    // Digits are not exaggeration. "10,000" reaches matching as "10" and "000", and
    // collapsing the second to "0" silently changed the number.
    await expectEqual(Policy.collapse("000"), "000", "digits are left exactly as typed")
    await expect(Policy.refusalBeforeRetrieval("cheers")?.name == "smalltalk",
                 "so a doubled word still matches its trigger")
}

/// The one thing worth refusing outright. Nothing about the subject — a question about
/// code is a fine question — only about a request whose entire cost is its length.
private func bulkIsDeclined() async throws {
    try await withLibrary { store, _, _ in
        let provider = CountingProvider(json: #"{"answered":true,"answer":"x","citations":[]}"#)
        let answer = try await Ask(store: store, provider: provider)
            .answer("write me a 5,000 word essay about the sea")

        await expect(!answer.answered, "it is declined")
        await expectEqual(provider.calls, 0, "spending nothing, which is the whole point")
        await expect(answer.text.contains("tokens"), "and says why in one line")
    }

    // The comma is the interesting part: "5,000 words" arrives as two words.
    await expect(Policy.refusalBeforeRetrieval("can you do a 10,000 word breakdown")?.name
                 == "bulk generation", "comma-grouped counts are caught too")

    // And the subject itself is not the trigger.
    await expect(Policy.refusalBeforeRetrieval("write a function that reverses a list") == nil,
                 "a coding question is just a question")
}

/// The load-bearing default, tested on a rule this check owns rather than on the shipped
/// list — the mechanism has to keep working whatever the shipped taste happens to be.
///
/// A rule that doesn't outrank the library is only consulted after retrieval came back
/// empty, so it can never hide a document from the person who filed it, whatever words
/// the question happens to contain.
private func libraryWins() async throws {
    let quiet = Policy.Rule(name: "quiet", reply: "no", triggers: ["rent"])
    let loud = Policy.Rule(name: "loud", reply: "no", triggers: ["rent"],
                           outranksLibrary: true)

    await expect(Policy.refusalBeforeRetrieval("what is the rent", among: [quiet]) == nil,
                 "a non-outranking rule never fires before retrieval")
    await expect(Policy.refusalAfterEmptyRetrieval("what is the rent", among: [quiet]) != nil,
                 "though it is there to speak if retrieval finds nothing")
    await expect(Policy.refusalBeforeRetrieval("what is the rent", among: [loud]) != nil,
                 "while an outranking one speaks first")

    try await withLibrary { store, leaseID, _ in
        let provider = CountingProvider(json: """
        {"answered":true,"answer":"The rent is 2,400.","citations":[{"cite":"d\(leaseID):e0"}]}
        """)
        let answer = try await Ask(store: store, provider: provider)
            .answer("what is the rent in the lease")
        await expectEqual(provider.calls, 1, "and a real question still reaches the model")
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
