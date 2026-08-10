import Foundation

/// Anything that can take a prompt and return JSON matching a schema.
///
/// Deliberately narrow. innerjoin asks models for exactly one thing — structured
/// extraction — so the abstraction is one method, and any provider that can be made
/// to emit conforming JSON fits behind it.
public protocol ModelProvider: Sendable {
    var label: String { get }
    func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data
}

public enum ProviderError: LocalizedError {
    case noKey(String)
    case http(Int, String)
    case malformed(String)
    /// The model answered, in words rather than JSON. Carries the words, because for a
    /// question that prose is usually a perfectly good answer — it just needs salvaging
    /// rather than discarding. Extraction can't use it; answering can.
    case notJSON(String)
    case noContent

    public var errorDescription: String? {
        switch self {
        case .noKey(let hint):    return "No API key. \(hint)"
        case .http(let code, let body):
            return "The model service returned \(code): \(body.prefix(200))"
        case .malformed(let why): return "The model's reply couldn't be read: \(why)"
        case .notJSON(let text):  return "The model answered in prose: \(text.prefix(120))"
        case .noContent:          return "The model returned nothing."
        }
    }

    /// What a credential looks like before any network call.
    ///
    /// Worth doing offline and first, because the failure this catches is not "wrong
    /// key" but "that isn't a key at all" — a password typed into a prompt that asked
    /// for one. Saying so immediately is the difference between a five-second fix and
    /// a secret sitting in the wrong place.
    public static func lookWrong(_ candidate: String, for provider: String) -> String? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "Nothing was entered." }
        if key.contains(" ") { return "That contains a space, so it isn't an API key." }

        let expected: String? = switch provider.lowercased() {
        case "openrouter": "sk-or-"
        case "anthropic":  "sk-ant-"
        case "openai":     "sk-"
        default:           nil    // local servers and gateways use anything, or nothing
        }
        guard let expected else { return nil }

        if !key.hasPrefix(expected) {
            // The specific mistake worth naming, because it's the one people make.
            let looksLikeAPassword = key.count < 40 && !key.contains("-")
            return looksLikeAPassword
                ? """
                  That looks like a password, not an API key — nothing was saved.
                  A key for \(provider) starts with "\(expected)" and is much longer.
                  Copy it from the provider's website, not from your password manager.
                  """
                : "A \(provider) key starts with \"\(expected)\". That doesn't, so nothing was saved."
        }
        if key.count < 24 { return "That's too short to be a key for \(provider)." }
        return nil
    }

    /// Whether a rejection is about the JSON schema we asked for rather than about us.
    ///
    /// Narrow on purpose: a malformed request, a bad key or an unknown model must still
    /// fail loudly. Retrying those would only double the noise.
    public static func isAboutTheSchema(_ complaint: String) -> Bool {
        let lowered = complaint.lowercased()
        return ["response_format", "json_schema", "structured output",
                "structured_output", "json schema", "response format"]
            .contains { lowered.contains($0) }
    }
}

/// How to reach a model. Keys are never written to the database or the vault — they
/// come from the environment or the Keychain and stay in memory.
public struct ProviderSettings: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Anthropic's Messages API.
        case anthropic
        /// Anything speaking OpenAI's chat-completions dialect — OpenAI itself, plus
        /// Ollama, LM Studio, OpenRouter, Together, vLLM. One adapter, most of the world.
        case openAICompatible
        /// Deterministic, offline. Used by the checks so they never need a key.
        case mock
    }

    public var kind: Kind
    public var model: String
    public var baseURL: URL
    public var apiKey: String?

    public init(kind: Kind, model: String, baseURL: URL, apiKey: String?) {
        self.kind = kind; self.model = model; self.baseURL = baseURL; self.apiKey = apiKey
    }

    /// Reads settings from the environment, falling back to the Keychain for the key.
    ///
    ///   IJ_PROVIDER   anthropic | openai | mock        (default: anthropic)
    ///   IJ_MODEL      model identifier
    ///   IJ_BASE_URL   override, e.g. http://localhost:11434/v1 for Ollama
    ///   IJ_API_KEY    the key; if unset, the Keychain is tried
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> ProviderSettings
    {
        let name = (environment["IJ_PROVIDER"] ?? "anthropic").lowercased()
        let kind: Kind = switch name {
        case "mock": .mock
        case "openai", "openai-compatible", "openrouter", "ollama", "local", "lmstudio",
             "together", "groq", "deepseek", "vllm": .openAICompatible
        default: .anthropic
        }

        let defaultModel = switch kind {
        case .anthropic:        "claude-sonnet-5"
        case .openAICompatible: "gpt-4.1-mini"
        case .mock:             "mock"
        }
        // The dialect is the same for all of these; only the address differs. Knowing
        // the common ones means a working setup is a provider name and a key, with no
        // URL to look up.
        let defaultBase: String
        switch name {
        case "openrouter": defaultBase = "https://openrouter.ai/api/v1/chat/completions"
        case "ollama":     defaultBase = "http://localhost:11434/v1/chat/completions"
        case "lmstudio":   defaultBase = "http://localhost:1234/v1/chat/completions"
        case "together":   defaultBase = "https://api.together.xyz/v1/chat/completions"
        case "groq":       defaultBase = "https://api.groq.com/openai/v1/chat/completions"
        case "deepseek":   defaultBase = "https://api.deepseek.com/v1/chat/completions"
        default:
            defaultBase = switch kind {
            case .anthropic:        "https://api.anthropic.com/v1/messages"
            case .openAICompatible: "https://api.openai.com/v1/chat/completions"
            case .mock:             "mock://local"
            }
        }

        let key = environment["IJ_API_KEY"] ?? Keychain.read(account: name)
        return ProviderSettings(
            kind: kind,
            model: environment["IJ_MODEL"] ?? defaultModel,
            baseURL: URL(string: environment["IJ_BASE_URL"] ?? defaultBase)!,
            apiKey: key
        )
    }

    public func makeProvider() -> any ModelProvider {
        switch kind {
        case .mock:             MockProvider()
        case .anthropic:        AnthropicProvider(settings: self)
        case .openAICompatible: OpenAICompatibleProvider(settings: self)
        }
    }
}

// MARK: - Shared HTTP

enum HTTP {
    static func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.noContent }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Models sometimes wrap JSON in prose or a code fence even when asked not to.
    /// Salvage the object rather than failing the whole document over punctuation.
    static func firstJSONObject(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { inString.toggle() }
            else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index]).data(using: .utf8)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
