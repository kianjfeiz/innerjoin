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
    case noContent

    public var errorDescription: String? {
        switch self {
        case .noKey(let hint):    return "No API key. \(hint)"
        case .http(let code, let body):
            return "The model service returned \(code): \(body.prefix(200))"
        case .malformed(let why): return "The model's reply couldn't be read: \(why)"
        case .noContent:          return "The model returned nothing."
        }
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
        case "openai", "openai-compatible", "ollama", "local": .openAICompatible
        default: .anthropic
        }

        let defaultModel = switch kind {
        case .anthropic:        "claude-sonnet-5"
        case .openAICompatible: "gpt-4.1-mini"
        case .mock:             "mock"
        }
        let defaultBase = switch kind {
        case .anthropic:        "https://api.anthropic.com/v1/messages"
        case .openAICompatible: "https://api.openai.com/v1/chat/completions"
        case .mock:             "mock://local"
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
