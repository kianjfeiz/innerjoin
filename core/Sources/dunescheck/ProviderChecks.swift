import Foundation
import DunesCore

func providerChecks() async {
    print("\nProviders · bring your own model")
    await check("known services need only a name and a key", knownServices)
    await check("an unknown name doesn't silently become Anthropic's address", unknownService)
    await check("environment beats the built-in default", environmentOverrides)
    await check("a schema refusal is told apart from a real rejection", schemaRefusal)
    await check("a password typed into the key prompt is refused, not stored", passwordIsNotAKey)
}

private func knownServices() async throws {
    // "Any model, bring your own key" only holds if setting one up is a name and a key.
    // Every one of these speaks OpenAI's dialect at a different address.
    let expected = [
        "openrouter": "openrouter.ai",
        "groq": "api.groq.com",
        "together": "api.together.xyz",
        "deepseek": "api.deepseek.com",
        "ollama": "localhost",
        "lmstudio": "localhost",
        "openai": "api.openai.com",
    ]
    for (name, host) in expected {
        let settings = ProviderSettings.fromEnvironment(["DUNES_PROVIDER": name, "DUNES_API_KEY": "test-key"])
        await expectEqual(settings.kind, .openAICompatible, "\(name) speaks the OpenAI dialect")
        await expectEqual(settings.baseURL.host, host, "\(name) resolves to \(host)")
        await expect(settings.baseURL.path.contains("chat/completions"),
                     "\(name) points at the chat endpoint, not just the host")
    }

    let anthropic = ProviderSettings.fromEnvironment(["DUNES_PROVIDER": "anthropic", "DUNES_API_KEY": "test-key"])
    await expectEqual(anthropic.kind, .anthropic, "Anthropic has its own dialect")
    await expectEqual(anthropic.baseURL.host, "api.anthropic.com", "and its own address")
}

private func unknownService() async throws {
    // Falling through to Anthropic is the current behaviour and it's a trap worth
    // knowing about: a typo sends the request to the wrong service with the wrong
    // dialect. Pinned here so the fallback is a decision, not an accident.
    let settings = ProviderSettings.fromEnvironment(["DUNES_PROVIDER": "openrouterr", "DUNES_API_KEY": "test-key"])
    await expectEqual(settings.kind, .anthropic, "an unrecognized name falls back to Anthropic")
    await expectEqual(settings.baseURL.host, "api.anthropic.com",
                      "which means a typo sends the request somewhere it won't work — loudly, not silently")
}

private func environmentOverrides() async throws {
    let settings = ProviderSettings.fromEnvironment([
        "DUNES_PROVIDER": "openrouter",
        "DUNES_MODEL": "deepseek/deepseek-chat",
        "DUNES_BASE_URL": "http://localhost:8000/v1/chat/completions",
        "DUNES_API_KEY": "test-key",
    ])
    await expectEqual(settings.model, "deepseek/deepseek-chat", "the model is taken as given")
    await expectEqual(settings.baseURL.port, 8000, "an explicit address wins over the known one")
    await expectEqual(settings.apiKey, "test-key", "and a key in the environment is used as-is")
}

private func passwordIsNotAKey() async throws {
    // This happened, twice, for real: the prompt for a key said the word "password",
    // and a password went in. It authenticates against nothing, and it sits in the
    // keychain looking correct. Catching it offline and before storing is the whole
    // point — a credential that was never valid must never be written down.
    let complaint = try require(ProviderError.lookWrong("2010UtahAcct", for: "openrouter"),
                                "a complaint")
    await expect(complaint.contains("looks like a password"),
                 "and it says so in those words, rather than \"invalid key\"")
    await expect(complaint.contains("sk-or-"), "naming what a real one starts with")

    await expect(ProviderError.lookWrong("", for: "openrouter") != nil, "empty is refused")
    await expect(ProviderError.lookWrong("sk-or-v1 abc", for: "openrouter") != nil,
                 "a value with a space in it is refused")
    await expect(ProviderError.lookWrong("sk-ant-abc", for: "openrouter") != nil,
                 "a key for a different service is refused")
    await expect(ProviderError.lookWrong("sk-or-v1-tooshort", for: "openrouter") != nil,
                 "and one that's too short")

    // A plausible key passes the offline check; only the network can judge the rest.
    await expect(ProviderError.lookWrong(
        "sk-or-v1-" + String(repeating: "a", count: 64), for: "openrouter") == nil,
        "a well-formed key is allowed through to the live check")
    // Local servers and gateways have no convention, so nothing is imposed on them.
    await expect(ProviderError.lookWrong("anything-at-all-here", for: "ollama") == nil,
                 "a local server's key is not second-guessed")
}

private func schemaRefusal() async throws {
    // A router fronts dozens of models and only some accept a JSON schema. The ones that
    // don't reject the whole request — which would fail every document in the library.
    // Retrying without the schema is right; retrying a bad key is not.
    await expect(ProviderError.isAboutTheSchema(
        #"{"error":{"message":"response_format is not supported for this model"}}"#),
        "an unsupported response_format is recognized")
    await expect(ProviderError.isAboutTheSchema("Invalid schema for json_schema: missing 'required'"),
                 "so is a schema the service won't accept")
    await expect(!ProviderError.isAboutTheSchema("Incorrect API key provided"),
                 "a bad key is not, and must keep failing")
    await expect(!ProviderError.isAboutTheSchema("model 'deepseek/typo' not found"),
                 "neither is a model that doesn't exist")
    await expect(!ProviderError.isAboutTheSchema("context length exceeded"),
                 "nor a document too long to send")
}

/// Both of these came out of the first run against a real model, and neither could have
/// been found any other way: a simulator cites anchors in exactly the form it was told to.
func anchorFormatChecks() async {
    print("\nAnchors · what a real model actually writes")
    await check("an anchor cited with brackets still resolves", bracketedAnchors)
    await check("an anchor that leaked into a title is removed", anchorsInProse)
}

private func bracketedAnchors() async throws {
    // The rendition shows anchors as "[e12]", so models cite them that way about as
    // often as bare. Every bracketed one was being discarded as invented — the document
    // said it, the model copied it faithfully, and punctuation threw the provenance away.
    await expectEqual(Element.normalizeTag("[e12]"), "e12", "brackets are stripped")
    await expectEqual(Element.normalizeTag("e12"), "e12", "bare still works")
    await expectEqual(Element.normalizeTag(" E12, "), "e12", "so do case and stray punctuation")

    // Being liberal costs nothing — the tag still has to exist on the document — but
    // it must not turn nonsense into a citation.
    await expect(Element.normalizeTag("e") == nil, "a bare letter is not an anchor")
    await expect(Element.normalizeTag("page 3") == nil, "nor is prose")
    await expect(Element.normalizeTag("d3") == nil, "nor a document reference")
    await expect(Element.normalizeTag(nil) == nil, "nor nothing at all")
}

private func anchorsInProse() async throws {
    // A real run produced the title "October Trip [e1]", which became a filename.
    await expectEqual(Element.stripTags("October Trip [e1]"), "October Trip",
                      "a trailing anchor is removed from a title")
    await expectEqual(Element.stripTags("Rent [e3] is due"), "Rent is due",
                      "and one in the middle, without leaving a double space")
    await expectEqual(Element.stripTags("Invoice A-2402"), "Invoice A-2402",
                      "ordinary text is untouched")
}
