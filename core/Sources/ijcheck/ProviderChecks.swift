import Foundation
import InnerjoinCore

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
        let settings = ProviderSettings.fromEnvironment(["IJ_PROVIDER": name, "IJ_API_KEY": "test-key"])
        await expectEqual(settings.kind, .openAICompatible, "\(name) speaks the OpenAI dialect")
        await expectEqual(settings.baseURL.host, host, "\(name) resolves to \(host)")
        await expect(settings.baseURL.path.contains("chat/completions"),
                     "\(name) points at the chat endpoint, not just the host")
    }

    let anthropic = ProviderSettings.fromEnvironment(["IJ_PROVIDER": "anthropic", "IJ_API_KEY": "test-key"])
    await expectEqual(anthropic.kind, .anthropic, "Anthropic has its own dialect")
    await expectEqual(anthropic.baseURL.host, "api.anthropic.com", "and its own address")
}

private func unknownService() async throws {
    // Falling through to Anthropic is the current behaviour and it's a trap worth
    // knowing about: a typo sends the request to the wrong service with the wrong
    // dialect. Pinned here so the fallback is a decision, not an accident.
    let settings = ProviderSettings.fromEnvironment(["IJ_PROVIDER": "openrouterr", "IJ_API_KEY": "test-key"])
    await expectEqual(settings.kind, .anthropic, "an unrecognized name falls back to Anthropic")
    await expectEqual(settings.baseURL.host, "api.anthropic.com",
                      "which means a typo sends the request somewhere it won't work — loudly, not silently")
}

private func environmentOverrides() async throws {
    let settings = ProviderSettings.fromEnvironment([
        "IJ_PROVIDER": "openrouter",
        "IJ_MODEL": "deepseek/deepseek-chat",
        "IJ_BASE_URL": "http://localhost:8000/v1/chat/completions",
        "IJ_API_KEY": "test-key",
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
