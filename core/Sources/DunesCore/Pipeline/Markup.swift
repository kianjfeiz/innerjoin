import Foundation

/// A model's reply, split into the things it is made of.
///
/// Answers used to be drawn as one run of text, which was fine while every answer was
/// two sentences about a lease. Ask this app a question it answers from its own knowledge
/// and it will hand back a fenced code block — and drawn as prose that is three backticks,
/// the word "python", and a wall of unindented monospace-less soup.
///
/// The parsing lives here rather than in the view for one reason: it has edge cases —
/// unterminated fences, empty fences, language tags, and the whole thing arriving one
/// chunk at a time — and edge cases want checks. The view does colour and layout only.
public enum Markup {

    public enum Block: Sendable, Equatable {
        /// Prose, with its inline markdown left in for the view to render.
        case prose(String)
        /// A fenced block. `closed` is false while the reply is still streaming and the
        /// closing fence hasn't arrived — the block is drawn as code from its first line
        /// regardless, because watching backticks turn into a code block after the fact
        /// is worse than either state on its own.
        case code(language: String?, text: String, closed: Bool)
    }

    /// Split a reply on ``` fences.
    ///
    /// Nothing else is treated as structure. Inline markdown — bold, `code`, links — is
    /// left in the prose for the view, which has a real markdown parser for it; this is
    /// only about finding the parts that must not be reflowed as sentences.
    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let joined = prose.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, text: trimmedBody(code), closed: true))
                    code = []
                    language = nil
                    inCode = false
                } else {
                    flushProse()
                    let tag = line.trimmingCharacters(in: .whitespaces)
                        .dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    language = tag.isEmpty ? nil : tag
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }

        if inCode {
            blocks.append(.code(language: language, text: trimmedBody(code), closed: false))
        } else {
            flushProse()
        }
        return blocks
    }

    /// Blank lines at either end of a fence are the fence's, not the code's.
    private static func trimmedBody(_ lines: [String]) -> String {
        var lines = lines
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Colour

    public enum Token: Sendable, Equatable {
        case plain, keyword, string, comment, number
    }

    public struct Span: Sendable, Equatable {
        public let text: String
        public let kind: Token
    }

    /// Enough highlighting to read by.
    ///
    /// Deliberately not a parser. Five token kinds, one pass, no grammar — which gets
    /// comments, strings, numbers and keywords right in every language anyone is likely
    /// to paste, and gets clever syntax subtly wrong in ways nobody reading an answer
    /// will care about. A real highlighter here would be a dependency and a per-language
    /// grammar in exchange for colouring a regex literal correctly.
    ///
    /// The one invariant worth holding is that concatenating the spans returns the input
    /// exactly. Highlighting that quietly eats a character would corrupt code somebody is
    /// about to copy, which is a much worse failure than a miscoloured keyword.
    public static func highlight(_ code: String, language: String?) -> [Span] {
        let keywords = Self.keywords(for: language)
        let hashComments = Self.hashComments(language)
        let slashComments = Self.slashComments(language)

        var spans: [Span] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { spans.append(Span(text: plain, kind: .plain)); plain = "" }
        }
        func emit(_ text: String, _ kind: Token) {
            flush()
            spans.append(Span(text: text, kind: kind))
        }

        let characters = Array(code)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            // Comments, to end of line or to the closing pair.
            if slashComments, character == "/", next == "/" {
                let start = index
                while index < characters.count, characters[index] != "\n" { index += 1 }
                emit(String(characters[start..<index]), .comment)
                continue
            }
            if slashComments, character == "/", next == "*" {
                let start = index
                index += 2
                while index < characters.count {
                    if characters[index] == "*", index + 1 < characters.count,
                       characters[index + 1] == "/" { index += 2; break }
                    index += 1
                }
                emit(String(characters[start..<index]), .comment)
                continue
            }
            if hashComments, character == "#" {
                let start = index
                while index < characters.count, characters[index] != "\n" { index += 1 }
                emit(String(characters[start..<index]), .comment)
                continue
            }

            // Strings. Unterminated ones run to the end of the line rather than eating
            // the rest of the block — a half-typed quote is common in streamed output.
            if character == "\"" || character == "'" || character == "`" {
                let quote = character
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" { index += 2; continue }
                    if characters[index] == "\n" { break }
                    if characters[index] == quote { index += 1; break }
                    index += 1
                }
                index = min(index, characters.count)
                emit(String(characters[start..<index]), .string)
                continue
            }

            // Numbers, but not the tail of an identifier like `utf8`.
            if character.isNumber, index == 0 || !(characters[index - 1].isLetter
                || characters[index - 1].isNumber || characters[index - 1] == "_") {
                let start = index
                while index < characters.count,
                      characters[index].isNumber || characters[index] == "." || characters[index] == "_" {
                    index += 1
                }
                emit(String(characters[start..<index]), .number)
                continue
            }

            // Words.
            if character.isLetter || character == "_" {
                let start = index
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "_" {
                    index += 1
                }
                let word = String(characters[start..<index])
                if keywords.contains(word) { emit(word, .keyword) } else { plain += word }
                continue
            }

            plain.append(character)
            index += 1
        }
        flush()
        return spans
    }

    // MARK: - What each language calls things

    private static func hashComments(_ language: String?) -> Bool {
        ["python", "py", "bash", "sh", "zsh", "shell", "ruby", "rb", "yaml", "yml",
         "toml", "r", "perl", "makefile"].contains(language ?? "")
    }

    private static func slashComments(_ language: String?) -> Bool {
        !hashComments(language)
    }

    private static func keywords(for language: String?) -> Set<String> {
        switch language {
        case "python", "py":
            ["def", "class", "if", "elif", "else", "for", "while", "return", "import",
             "from", "as", "with", "try", "except", "finally", "raise", "lambda", "pass",
             "break", "continue", "in", "not", "and", "or", "is", "None", "True", "False",
             "self", "yield", "async", "await", "global", "assert", "del", "print"]
        case "swift":
            ["func", "let", "var", "if", "else", "guard", "return", "struct", "class",
             "enum", "protocol", "extension", "import", "for", "in", "while", "switch",
             "case", "default", "try", "catch", "throw", "throws", "async", "await",
             "public", "private", "internal", "static", "self", "nil", "true", "false",
             "init", "some", "any", "where", "typealias", "defer"]
        case "javascript", "js", "typescript", "ts", "jsx", "tsx":
            ["function", "const", "let", "var", "if", "else", "for", "while", "return",
             "class", "extends", "import", "from", "export", "default", "new", "this",
             "null", "undefined", "true", "false", "async", "await", "try", "catch",
             "finally", "throw", "typeof", "instanceof", "interface", "type", "enum",
             "public", "private", "of", "in"]
        case "bash", "sh", "zsh", "shell":
            ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
             "case", "esac", "function", "echo", "export", "local", "return", "source"]
        case "sql":
            ["select", "from", "where", "join", "left", "inner", "outer", "on", "group",
             "by", "order", "limit", "insert", "into", "values", "update", "set",
             "delete", "create", "table", "index", "and", "or", "not", "null", "as"]
        case "json":
            ["true", "false", "null"]
        default:
            // A union of the common ones, so an untagged block still reads as code.
            ["func", "function", "def", "class", "let", "const", "var", "if", "else",
             "elif", "for", "while", "return", "import", "from", "struct", "enum",
             "public", "private", "static", "try", "catch", "throw", "async", "await",
             "true", "false", "null", "nil", "None", "True", "False", "self", "this",
             "new", "in", "not", "and", "or"]
        }
    }
}
