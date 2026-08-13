import Foundation

/// Anthropic's Messages API. Structured output is enforced by handing the model a
/// single tool and requiring it — the reply arrives as validated tool input.
struct AnthropicProvider: ModelProvider {
    let settings: ProviderSettings
    var label: String { "Anthropic · \(settings.model)" }

    func extract(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> Data {
        guard let key = settings.apiKey, !key.isEmpty else {
            throw ProviderError.noKey("Set DUNES_API_KEY, or store one with `dunes key set`.")
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
        let schemaWithClosedObjects = StrictSchema.rewrite(schema) as? [String: Any] ?? schema

        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": maxTokens,
            // Extraction has a right answer, so there is nothing for sampling to
            // explore. Left at the default, two runs of the same corpus scored 93% and
            // 57% on category purity with no change in between — which makes every
            // measurement a coin flip and every "improvement" unfalsifiable.
            "temperature": 0,
            // Sent because it costs nothing and can only help. It does **not** buy
            // reproducibility, and it is worth being exact about that, because assuming
            // it did would quietly invalidate every measurement taken afterwards.
            //
            // Tested rather than trusted: the same request, three times, same seed, same
            // temperature — three different replies, of 2347, 2366 and 2368 characters. A
            // one-line question does come back identical, which is what makes the promise
            // so easy to believe; a real extraction has thousands of places to diverge and
            // takes one of them. The provider returns no `system_fingerprint` here, so
            // there isn't even a way to know when the machine underneath has changed.
            //
            // The consequence is a fact about measurement, not about this parameter: a
            // single run of the corpus is one sample, so anything that moves run to run
            // has to be run repeatedly and reported with its spread. `duneseval --real
            // --repeat` exists for that reason.
            "seed": Int(ProcessInfo.processInfo.environment["DUNES_SEED"] ?? "") ?? 20_260_811,
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
        // Reasoning models spend their output budget thinking before they write, and
        // the thinking is billed and then thrown away. Measured on a real run: 306
        // completion tokens with it, 18 without, for the same answer — and on longer
        // documents the budget ran out mid-thought, so the reply arrived empty and the
        // document went unread. Extraction is a copying task, not a puzzle.
        //
        // The parameter is a router extension, so it's only sent where it's understood.
        // `DUNES_REASONING` turns it back on for a model that genuinely needs it.
        if settings.baseURL.host?.contains("openrouter") == true {
            let wanted = ProcessInfo.processInfo.environment["DUNES_REASONING"]?.lowercased()
            switch wanted {
            case nil, "", "off", "false", "none":
                body["reasoning"] = ["enabled": false]
            case "low", "medium", "high":
                body["reasoning"] = ["effort": wanted!]
            default:
                break
            }
            // A router fans one model out across several upstream providers, and they
            // don't all honour the same parameters. That is what made truncation
            // *intermittent*: most runs landed on a provider that turned reasoning off as
            // asked, and one in four landed on one that ignored it, spent the whole token
            // budget thinking, and returned an object cut off mid-field. Requiring
            // parameter support makes the routing match the request instead of the
            // failure being a lottery.
            if await RoutingPreference.shared.strictnessWorks(for: settings.model) {
                body["provider"] = ["require_parameters": true]
            }
        }

        var headers: [String: String] = [:]
        // Local servers usually need no key; hosted ones do.
        if let key = settings.apiKey, !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }

        var data: Data
        do {
            data = try await HTTP.post(settings.baseURL, headers: headers, body: body)
        } catch ProviderError.http(let code, let complaint) where code == 400
                    && complaint.lowercased().contains("reasoning") {
            // A model that doesn't take the parameter at all.
            body.removeValue(forKey: "reasoning")
            data = try await HTTP.post(settings.baseURL, headers: headers, body: body)
        } catch ProviderError.http(let code, let complaint) where (code == 404 || code == 400)
                    && ProviderError.isAboutRouting(complaint) {
            // Strictness is a preference, not a requirement. Relax it and let the router
            // pick an endpoint that ignores what it doesn't know, rather than failing the
            // document outright.
            body.removeValue(forKey: "provider")
            await RoutingPreference.shared.strictnessFailed(for: settings.model)
            do {
                data = try await HTTP.post(settings.baseURL, headers: headers, body: body)
            } catch ProviderError.http(let code, let complaint) where (code == 404 || code == 400)
                        && ProviderError.isAboutRouting(complaint) {
                // Still unroutable: the sampling controls are the usual culprits, and a
                // reasoning model that fixes its own temperature is the common case.
                body.removeValue(forKey: "temperature")
                body.removeValue(forKey: "seed")
                data = try await HTTP.post(settings.baseURL, headers: headers, body: body)
            }
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
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw ProviderError.malformed("unexpected response shape")
        }
        let text = message["content"] as? String ?? ""
        // Say *why* nothing came back. "Returned nothing" sent me looking at the prompt
        // when the answer was that the reply had been cut off mid-sentence.
        if text.trimmed.isEmpty {
            let reason = first["finish_reason"] as? String ?? "unknown"
            throw ProviderError.malformed(reason == "length"
                ? "the reply was cut off before any content (finish_reason: length) — raise maxTokens or turn off reasoning"
                : "the reply had no content (finish_reason: \(reason))")
        }
        guard let object = HTTP.firstJSONObject(in: text) else {
            throw ProviderError.notJSON(text)
        }
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

/// OpenAI's strict structured-output mode is a *subset* of JSON Schema, not a superset.
/// Two rules the spec doesn't have: every object must forbid extra properties, and every
/// property must be listed in `required` — optionality is expressed by admitting null,
/// never by omission. A perfectly valid schema is rejected with a 400.
///
/// Measured: with the schema as written, `openai/gpt-5.6-luna` refused all seven identity
/// documents. Setting `additionalProperties` on the root alone wasn't enough — the
/// validator descends into `items`, and every nested object has to satisfy both rules
/// too. It costs nothing on providers that don't enforce it, because a closed object and
/// an explicit null are legal everywhere.
enum StrictSchema {
    static func rewrite(_ node: Any) -> Any {
        guard var object = node as? [String: Any] else { return node }

        if let properties = object["properties"] as? [String: Any] {
            let optional = Set(properties.keys).subtracting(object["required"] as? [String] ?? [])
            object["properties"] = properties.mapValues { child in
                rewrite(child)
            }.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = optional.contains(pair.key) ? admittingNull(pair.value) : pair.value
            }
            // Sorted rather than in dictionary order: Swift hashes are seeded per process,
            // so the same schema would otherwise serialise differently on every launch and
            // defeat the router's prompt cache — which is 10× cheaper than a fresh read.
            object["required"] = properties.keys.sorted()
            object["additionalProperties"] = false
        }
        if let items = object["items"] { object["items"] = rewrite(items) }
        return object
    }

    /// A field the document simply doesn't mention still has to appear in the reply, so
    /// it has to be allowed to come back empty.
    private static func admittingNull(_ node: Any) -> Any {
        guard var object = node as? [String: Any] else { return node }
        if let single = object["type"] as? String, single != "null" {
            object["type"] = [single, "null"]
            // A closed vocabulary that may be absent has to count absence as one of its
            // options, or the value contradicts the very list it's checked against.
            if var choices = object["enum"] as? [Any] {
                choices.append(NSNull())
                object["enum"] = choices
            }
        }
        return object
    }
}

/// Remembers which models refused to be routed strictly, so the discovery costs one
/// failed request per model per launch instead of one per document.
///
/// Asking the router for an endpoint that honours every parameter is worth doing — it's
/// what stopped DeepSeek's intermittent truncation. But a model that fixes its own
/// temperature can't satisfy the ask, and re-learning that on all 36 documents of a
/// library doubles the request count for nothing.
actor RoutingPreference {
    static let shared = RoutingPreference()
    private var refused: Set<String> = []

    func strictnessWorks(for model: String) -> Bool { !refused.contains(model) }
    func strictnessFailed(for model: String) { refused.insert(model) }
}
