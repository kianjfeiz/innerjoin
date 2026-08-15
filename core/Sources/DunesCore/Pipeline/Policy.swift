import Foundation

/// What the app will answer, and what it says when it won't.
///
/// **This is the file to edit.** Everything the app declines to do is one `Rule` in
/// `rules` below. A rule is four things: what to look for, what to say instead, how much
/// of the question has to match, and whether it outranks the library. Add one, delete
/// one, reorder them — nothing else in the codebase needs to change.
///
/// It runs *before* the model, never after, so a declined question costs nothing: no API
/// call, no key read, no wait. That is also why the matching is plain words rather than a
/// classifier — a gate that has to phone a model in order to decide whether to phone a
/// model is not a gate.
///
/// The list is deliberately short. This app answers what it's asked — from the person's
/// files first, and from what it knows when the files don't have it — so a rule here is
/// not "this subject is off limits", it is "this specific request is not worth what it
/// costs". At the time of writing that is exactly one thing: generation priced by the
/// yard.
public enum Policy {

    /// How much of the question a trigger has to account for.
    public enum Match: Sendable {
        /// The trigger appears anywhere in the question. Use for subjects — a question
        /// about writing a regex is about writing a regex wherever the phrase falls.
        case anywhere
        /// The question is *made of* this rule's words and nothing else. Use for things
        /// that are only themselves when they stand alone: "hi" is a greeting, and
        /// "hi, what does my lease say?" is a question about a lease.
        case whole
    }

    public struct Rule: Sendable, Equatable {
        /// What this rule is called, for checks and for reading the list.
        public var name: String
        /// What the person is told instead of an answer.
        ///
        /// Worth writing carefully. A refusal that only says no leaves someone guessing
        /// whether they asked badly or the app is broken; one that says what the app
        /// *is* for turns a dead end into an instruction.
        public var reply: String
        /// Whole words and phrases, lowercased. Any single one firing is enough.
        public var triggers: [String]
        public var match: Match = .anywhere
        /// Fire even when the library holds documents matching the question.
        ///
        /// Off by default, and the default is the important part: someone whose library
        /// is full of source code must still be able to ask about their own source code.
        /// Left off, a rule only speaks when retrieval found nothing at all, so it can
        /// never stand between a person and their own files — it only ever replaces the
        /// generic "nothing in your files mentions that" with something more useful.
        ///
        /// Turn it on for questions the app should refuse whatever happens to be filed.
        public var outranksLibrary = false

        public init(name: String, reply: String, triggers: [String],
                    match: Match = .anywhere, outranksLibrary: Bool = false) {
            self.name = name
            self.reply = reply
            self.triggers = triggers
            self.match = match
            self.outranksLibrary = outranksLibrary
        }
    }

    // MARK: - The list

    public static let rules: [Rule] = [

        Rule(
            name: "smalltalk",
            reply: "Hey. Ask me anything — your own files first, since that's where I'm "
                + "actually worth something.",
            triggers: [
                "hi", "hii", "hello", "hey", "heya", "hiya", "yo", "howdy", "sup",
                "good morning", "good afternoon", "good evening",
                "thanks", "thank you", "cheers", "ok", "okay", "test", "testing", "ping",
            ],
            // Whole-question only, and it outranks the library: a greeting should never
            // be dragged through retrieval, and "hi" is a greeting only when it is the
            // entire message.
            match: .whole,
            outranksLibrary: true
        ),

        Rule(
            name: "bulk generation",
            reply: "Not doing that one — that's a lot of tokens for something that "
                + "isn't your files. Ask me something you actually need.",
            // The only thing worth refusing outright: requests whose whole cost is
            // length. This outranks the library because the point is to spend nothing —
            // no retrieval, no model call, no wait.
            //
            // Comma-grouped numbers arrive split, so "10,000 words" reaches matching as
            // "10 000 words" — hence the bare "000 words".
            triggers: [
                "write a novel", "write a book", "write an entire", "write me an entire",
                "full length", "as long as you can", "as many as you can",
                "keep going until", "repeat the following", "repeat this",
                "000 words", "000 word", "1000 words", "2000 words", "5000 words",
                "list 100", "list 500", "list 1000", "generate 100", "generate 1000",
            ],
            outranksLibrary: true
        ),
    ]

    /// Words that don't change what a question is. Only consulted by `.whole`, so that
    /// "hey there" and "hi dunes" are still greetings.
    static let filler: Set<String> = [
        "there", "dunes", "again", "all", "everyone", "you", "u", "please", "mate",
    ]

    // MARK: - The two moments a rule can speak

    /// Rules that outrank the library. Checked before retrieval runs, so a declined
    /// question touches neither the database nor the model.
    public static func refusalBeforeRetrieval(
        _ question: String, among rules: [Rule] = Policy.rules
    ) -> Rule? {
        first(matching: question, among: rules.filter(\.outranksLibrary))
    }

    /// Rules that only speak once retrieval has found nothing. This is where most rules
    /// live: they don't block a question, they explain a miss better than the generic
    /// answer could.
    public static func refusalAfterEmptyRetrieval(
        _ question: String, among rules: [Rule] = Policy.rules
    ) -> Rule? {
        first(matching: question, among: rules)
    }

    // MARK: - Matching

    static func first(matching question: String, among rules: [Rule]) -> Rule? {
        let words = self.words(in: question)
        guard !words.isEmpty else { return nil }
        let padded = " " + words.joined(separator: " ") + " "

        return rules.first { rule in
            switch rule.match {
            case .anywhere:
                return rule.triggers.contains { padded.contains(" \($0) ") }
            case .whole:
                // Every word in the question has to come from this rule's own
                // vocabulary, so a greeting with a real question attached is a real
                // question.
                let vocabulary = Set(rule.triggers.flatMap { $0.split(separator: " ").map(String.init) })
                guard rule.triggers.contains(where: { padded.contains(" \($0) ") }) else {
                    return false
                }
                return words.allSatisfy { vocabulary.contains($0) || filler.contains($0) }
            }
        }
    }

    /// Lowercased words, with punctuation dropped and any character repeated three
    /// times or more collapsed to one — so "hiiiiii" is "hi" and "heyyyy" is "hey",
    /// which is how people actually type a greeting.
    public static func words(in question: String) -> [String] {
        question.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { collapse(String($0)) }
    }

    /// Runs of three or more become one. Runs of two are left alone, because English is
    /// full of them — "cheers", "coffee", "letter" — and exaggeration isn't.
    ///
    /// Letters only. Digits are load-bearing: "10,000" arrives here as "10" and "000",
    /// and collapsing the second to "0" quietly turned every comma-grouped number into a
    /// different number. A rule matching on "000 words" stopped firing and the checks
    /// caught it.
    public static func collapse(_ word: String) -> String {
        var out = ""
        var index = word.startIndex
        while index < word.endIndex {
            let character = word[index]
            var scan = index
            var run = 0
            while scan < word.endIndex, word[scan] == character {
                run += 1
                scan = word.index(after: scan)
            }
            let collapses = run >= 3 && character.isLetter
            out.append(String(repeating: character, count: collapses ? 1 : run))
            index = scan
        }
        return out
    }
}
