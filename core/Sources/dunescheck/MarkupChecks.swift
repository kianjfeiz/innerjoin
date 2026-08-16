import Foundation
import DunesCore

/// Splitting a reply into prose and code, and colouring the code.
///
/// The colours are a matter of taste and aren't checked. What is checked is the part that
/// can silently corrupt something: a highlighter that drops a character hands somebody
/// broken code with a copy button next to it, and it would look completely fine.
func markupChecks() async {
    print("\nMarkup · prose, code, and the seam between them")
    await check("a fenced block is lifted out of the prose around it", fencesSplit)
    await check("a fence still arriving is already a code block", unterminatedFence)
    await check("highlighting never loses a character", nothingLost)
    await check("comments follow the language, not a guess", commentsPerLanguage)
    await check("strings, numbers and keywords are told apart", tokensAreTold)
    await check("a number inside a name is part of the name", numbersInNames)
}

private func fencesSplit() async throws {
    let blocks = Markup.blocks("""
        Here you go:

        ```python
        x = 1
        ```

        That's the fix.
        """)

    await expectEqual(blocks.count, 3, "prose, code, prose")
    guard blocks.count == 3 else { return }
    await expect(blocks[0] == .prose("Here you go:"), "the lead-in keeps its text")
    await expect(blocks[1] == .code(language: "python", text: "x = 1", closed: true),
                 "the block keeps its language and loses its fences")
    await expect(blocks[2] == .prose("That's the fix."), "and the trailing line survives")

    // An untagged fence is still a fence.
    let bare = Markup.blocks("```\nls -la\n```")
    await expect(bare == [.code(language: nil, text: "ls -la", closed: true)],
                 "a fence with no language is still code")
}

/// Answers arrive a chunk at a time, so for a second or two every code block is
/// unterminated. Drawing it as prose until the closing fence lands would mean watching
/// backticks sit there and then jump into a box.
private func unterminatedFence() async throws {
    let blocks = Markup.blocks("Try:\n\n```swift\nlet x = 1\nlet y =")
    await expectEqual(blocks.count, 2, "the half-arrived block is already a block")
    guard blocks.count == 2 else { return }
    await expect(blocks[1] == .code(language: "swift", text: "let x = 1\nlet y =", closed: false),
                 "with what has arrived so far, marked unclosed")
}

/// The one invariant that matters. Colouring is decoration; losing a character is
/// handing someone code that won't run, with a copy button beside it.
private func nothingLost() async throws {
    let samples = [
        "let x = \"hi\" // a note\nreturn 1_000",
        "# comment\ndef f(a='x'):\n    return a[0]",
        "unterminated \"string",
        "/* block\n   comment */ x",
        "",
        "````",
        "emoji 🙂 and \\n escapes",
    ]
    for sample in samples {
        for language in ["swift", "python", nil] {
            let rebuilt = Markup.highlight(sample, language: language)
                .map(\.text).joined()
            await expectEqual(rebuilt, sample,
                              "\(language ?? "untagged") highlighting is lossless")
        }
    }
}

private func commentsPerLanguage() async throws {
    let hash = Markup.highlight("#include <stdio.h>", language: "swift")
    await expect(!hash.contains { $0.kind == .comment },
                 "a hash is not a comment in a brace language")

    let python = Markup.highlight("# really a comment", language: "python")
    await expect(python.contains { $0.kind == .comment },
                 "and it is in python")

    let slashes = Markup.highlight("x = 1 // note", language: "swift")
    await expect(slashes.contains { $0.kind == .comment && $0.text == "// note" },
                 "double slashes run to the end of the line")
}

private func tokensAreTold() async throws {
    let spans = Markup.highlight("let name = \"Dana\" + 42", language: "swift")
    await expect(spans.contains { $0.kind == .keyword && $0.text == "let" }, "keywords")
    await expect(spans.contains { $0.kind == .string && $0.text == "\"Dana\"" }, "strings")
    await expect(spans.contains { $0.kind == .number && $0.text == "42" }, "numbers")
}

/// `utf8` is one word. Colouring the 8 would make identifiers flicker mid-name.
private func numbersInNames() async throws {
    let spans = Markup.highlight("String(utf8)", language: "swift")
    await expect(!spans.contains { $0.kind == .number },
                 "a digit inside an identifier stays part of it")
}
