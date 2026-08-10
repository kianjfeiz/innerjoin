import Foundation

/// Anthropic's Messages API. Structured output is enforced by handing the model a
/// single tool and requiring it — the reply arrives as validated tool input.
struct AnthropicProvider: ModelProvider {
    let settings: ProviderSettings
    var label: String { "Anthropic · \(settings.model)" }

    func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data {
        guard let key = settings.apiKey, !key.isEmpty else {
            throw ProviderError.noKey("Set IJ_API_KEY, or store one with `ijparse key set`.")
        }
        let body: [String: Any] = [
            "model": settings.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "tools": [[
                "name": "record_document",
                "description": "Return the structured record for this document.",
                "input_schema": schema,
            ]],
            "tool_choice": ["type": "tool", "name": "record_document"],
        ]
        let data = try await HTTP.post(settings.baseURL, headers: [
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        ], body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ProviderError.malformed("unexpected response shape")
        }
        let usage = json["usage"] as? [String: Any]
        await Meter.shared.record(input: usage?["input_tokens"] as? Int,
                                  output: usage?["output_tokens"] as? Int)
        for block in content where block["type"] as? String == "tool_use" {
            if let input = block["input"] {
                return try JSONSerialization.data(withJSONObject: input)
            }
        }
        // Some models answer in prose despite the tool. Salvage what's there.
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard let salvaged = HTTP.firstJSONObject(in: text) else { throw ProviderError.noContent }
        return salvaged
    }
}

/// Anything speaking OpenAI's chat-completions dialect: OpenAI, Ollama, LM Studio,
/// OpenRouter, vLLM. Uses `response_format: json_schema` where supported and falls
/// back to salvaging JSON from the text when it isn't.
struct OpenAICompatibleProvider: ModelProvider {
    let settings: ProviderSettings
    var label: String { "\(settings.baseURL.host ?? "local") · \(settings.model)" }

    func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data {
        var schemaWithClosedObjects = schema
        // Strict mode requires this; harmless where it isn't supported.
        schemaWithClosedObjects["additionalProperties"] = false

        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "record_document",
                    "schema": schemaWithClosedObjects,
                ],
            ],
        ]
        var headers: [String: String] = [:]
        // Local servers usually need no key; hosted ones do.
        if let key = settings.apiKey, !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }

        var data: Data
        do {
            data = try await HTTP.post(settings.baseURL, headers: headers, body: body)
        } catch ProviderError.http(let code, let complaint) where code == 400
                    && ProviderError.isAboutTheSchema(complaint) {
            // "Any model, bring your own key" means the fleet is heterogeneous: a router
            // fronts dozens of models and only some of them accept a JSON schema. The
            // ones that don't reject the whole request, which would fail every document
            // in the library over a field we asked for politely. Drop it and ask again —
            // the system prompt already demands JSON, and the reply is salvaged below
            // either way. One extra round trip, once, beats an unusable provider.
            body.removeValue(forKey: "response_format")
            data = try await HTTP.post(settings.baseURL, headers: headers, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformed("the reply wasn't JSON")
        }
        let usage = json["usage"] as? [String: Any]
        await Meter.shared.record(input: usage?["prompt_tokens"] as? Int,
                                  output: usage?["completion_tokens"] as? Int)

        // A router can answer 200 and put the failure in the body.
        if let error = json["error"] as? [String: Any] {
            throw ProviderError.malformed(error["message"] as? String ?? "the provider reported an error")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw ProviderError.malformed("unexpected response shape")
        }
        guard let object = HTTP.firstJSONObject(in: text) else { throw ProviderError.noContent }
        return object
    }
}

/// Offline stand-in. Produces a plausible record from the text it's given by pulling
/// out the first heading, an amount, and a date — enough to exercise the schema,
/// validation, and persistence without a key or a network.
public struct MockProvider: ModelProvider {
    public init() {}
    public var label: String { "Mock (offline)" }

    public func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data {
        let anchors = matches(#"\[(e\d+)\]"#, in: user).map { String($0.dropFirst().dropLast()) }
        let anchor = anchors.first ?? "e0"

        let heading = user
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmed }
            ?? "Untitled document"

        let amount = matches(#"\$[\d,]+(\.\d{2})?"#, in: user).first?
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        let date = matches(#"\d{4}-\d{2}-\d{2}"#, in: user).first

        var record: [String: Any] = [
            "title": heading,
            "kind": "document",
            "summary": "A mock summary of \(heading).",
            "category": "Everything else",
            "fields": [
                ["name": "heading", "value": heading, "source": anchor],
            ],
            "dates": [],
            "entities": [],
        ]
        if let amount {
            record["amount"] = Double(amount) ?? 0
            record["currency"] = "USD"
            var fields = record["fields"] as! [[String: Any]]
            fields.append(["name": "amount", "value": "$\(amount)", "source": anchor])
            record["fields"] = fields
        }
        if let date {
            record["happened_on"] = date
            record["dates"] = [["kind": "mentioned", "date": date, "source": anchor]]
        }
        return try JSONSerialization.data(withJSONObject: record)
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
