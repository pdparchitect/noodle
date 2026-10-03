import XCTest
@testable import NoodleCore

final class RemoteModelsTests: XCTestCase {
    private var root: URL!
    private var secrets: MemoryRemoteModelSecrets!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-models-\(UUID())").resolvingSymlinksInPath()
        secrets = MemoryRemoteModelSecrets()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var store: RemoteModelAccountStore { RemoteModelAccountStore(repository: root, secrets: secrets) }

    func testModelIdentifierNamesProviderAccountAndModel() throws {
        let account = UUID()
        let id = RemoteModelID(providerID: "openai", accountID: account, modelID: "gpt-6-luna")
        XCTAssertEqual(id.rawValue, "remote/openai/\(account.uuidString.lowercased())/gpt-6-luna")
        XCTAssertEqual(RemoteModelID(id.rawValue), id)
        XCTAssertTrue(FxProtocol.validIdentifier(id.rawValue), "The Agent Host accepts it as a model argument")
        XCTAssertFalse(AppleLocalModelStore.validIdentifier(id.rawValue))
        for invalid in ["default", "mlx-\(UUID())", "remote/openai/not-a-uuid/gpt-6-luna", "remote/openai/\(account)/",
                        "remote//\(account)/gpt-6-luna", "remote/openai/\(account)/gpt 6", "remote/openai/\(account)"] {
            XCTAssertNil(RemoteModelID(invalid), invalid)
        }
    }

    func testOpenAIListsCheckedModelsAndChoosesResponsesForThem() throws {
        let openAI = try XCTUnwrap(RemoteProviders.provider(id: "openai"))
        XCTAssertEqual(openAI.displayName, "OpenAI")
        XCTAssertEqual(openAI.models.map(\.id), ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "gpt-5.6-terra"])
        XCTAssertEqual(openAI.model(id: "gpt-5.6-terra")?.efforts.map(\.id), ["none", "low", "medium", "high", "xhigh", "max"])
        let luna = try XCTUnwrap(openAI.model(id: "gpt-6-luna"))
        XCTAssertEqual(luna.contextSize, 922_000)
        XCTAssertTrue(luna.supportsImages)
        XCTAssertEqual(luna.efforts.map(\.id), ["none", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(luna.defaultEffort, "medium")
        XCTAssertEqual(openAI.model(id: "gpt-6-astra")?.efforts.map(\.id), ["low", "medium", "high", "xhigh", "max"])
        for model in openAI.models { XCTAssertTrue(openAI.api(for: model) is ResponsesAPI, model.id) }
        XCTAssertNil(openAI.model(id: "gpt-3.5-turbo"), "Only models Noodle has checked can be enabled")
    }

    func testGatewaysOfferTheLatestGLMDeepSeekAndQwenOverChatCompletions() throws {
        XCTAssertEqual(RemoteProviders.all.map(\.id), ["openai", "openrouter", "vercel", "ollama", "custom"])
        let openRouter = try XCTUnwrap(RemoteProviders.provider(id: "openrouter"))
        XCTAssertEqual(openRouter.displayName, "OpenRouter")
        XCTAssertEqual(openRouter.baseURL.absoluteString, "https://openrouter.ai/api/v1")
        XCTAssertEqual(openRouter.models.map(\.id), ["z-ai/glm-5.3", "z-ai/glm-5.3-flash", "deepseek/deepseek-v4-pro-0813",
                                                     "deepseek/deepseek-v4.1-flash", "qwen/qwen3.8-max-prime", "qwen/qwen3.8-flash"])
        let vercel = try XCTUnwrap(RemoteProviders.provider(id: "vercel"))
        XCTAssertEqual(vercel.displayName, "Vercel AI Gateway")
        XCTAssertEqual(vercel.baseURL.absoluteString, "https://ai-gateway.vercel.sh/v1")
        XCTAssertEqual(vercel.models.map(\.id), ["zai/glm-5.3", "zai/glm-5.3-flash", "deepseek/deepseek-v4-pro-0813",
                                                 "deepseek/deepseek-v4.1-flash", "alibaba/qwen3.8-max-prime", "alibaba/qwen3.8-flash"])
        for provider in [openRouter, vercel] {
            XCTAssertEqual(provider.models.map(\.displayName), ["GLM-5.3", "GLM-5.3 Flash", "DeepSeek V4 Pro", "DeepSeek V4.1 Flash",
                                                                "Qwen3.8 Max Prime", "Qwen3.8 Flash"])
            for model in provider.models { XCTAssertTrue(provider.api(for: model) is GatewayChatAPI, model.id) }
            XCTAssertEqual(provider.models.map { $0.efforts.map(\.id) }, [
                ["low", "high", "max"], ["low", "high", "max"], ["none", "low", "high", "max"], ["none", "low", "high", "max"],
                ["low", "medium", "xhigh"], ["low", "medium", "xhigh"]])
            XCTAssertEqual(provider.models.map(\.supportsImages), [false, true, false, true, true, true])
        }
        XCTAssertEqual(vercel.model(id: "deepseek/deepseek-v4.1-flash")?.maximumOutputTokens, 32_768,
                       "Each gateway's own limits are kept")
        let id = RemoteModelID(providerID: "openrouter", accountID: UUID(), modelID: "z-ai/glm-5.3")
        XCTAssertEqual(RemoteModelID(id.rawValue), id, "Gateway model names contain a slash")
        XCTAssertEqual(id.model?.displayName, "GLM-5.3")
    }

    func testAccountsKeepTheirKeysApartAndListOnlyEnabledModels() throws {
        let work = try store.add(providerID: "openai", name: "Work", apiKey: "sk-work")
        let personal = try store.add(providerID: "openai", name: "Personal", apiKey: "sk-personal")
        try store.setModel("gpt-6-luna", enabled: true, account: work.id)
        try store.setModel("gpt-6-luna", enabled: true, account: personal.id)
        try store.setModel("gpt-6-astra", enabled: true, account: personal.id)

        XCTAssertEqual(try store.apiKey(for: work.id), "sk-work")
        XCTAssertEqual(try store.apiKey(for: personal.id), "sk-personal")
        let models = try store.harnessModels()
        XCTAssertEqual(models.count, 3, "The same model on two accounts is two choices")
        let workLuna = try XCTUnwrap(models.first { $0.id == RemoteModelID(providerID: "openai", accountID: work.id, modelID: "gpt-6-luna").rawValue })
        XCTAssertEqual(workLuna.displayName, "GPT-6 Luna")
        XCTAssertEqual(workLuna.tag, "OpenAI · Work")
        XCTAssertEqual(workLuna.supportedEfforts.map(\.id), ["none", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(workLuna.defaultEffort, "medium")
        XCTAssertFalse(workLuna.isDefault)

        let reloaded = RemoteModelAccountStore(repository: root, secrets: secrets)
        XCTAssertEqual(try reloaded.accounts().map(\.name), ["Personal", "Work"])
        try reloaded.remove(personal.id)
        XCTAssertNil(try secrets.read(personal.id), "Removing an account deletes its key")
        XCTAssertEqual(try reloaded.harnessModels().map(\.tag), ["OpenAI · Work"])
    }

    func testDisablingAModelAndUnknownProvidersAreRejectedOrIgnored() throws {
        let account = try store.add(providerID: "openai", name: "Work", apiKey: "sk-work")
        XCTAssertThrowsError(try store.setModel("gpt-3.5-turbo", enabled: true, account: account.id))
        XCTAssertThrowsError(try store.add(providerID: "nobody", name: "X", apiKey: "k"))
        XCTAssertThrowsError(try store.add(providerID: "openai", name: "  ", apiKey: "k"))
        XCTAssertThrowsError(try store.add(providerID: "openai", name: "Work", apiKey: " "))
        try store.setModel("gpt-6-luna", enabled: true, account: account.id)
        try store.setModel("gpt-6-luna", enabled: false, account: account.id)
        XCTAssertTrue(try store.harnessModels().isEmpty)
    }

    func testRemoteModelsKeepTheAppleHarnessAvailableWithoutAppleIntelligence() throws {
        let remote = HarnessModel(id: "remote/openai/\(UUID().uuidString.lowercased())/gpt-6-luna", displayName: "GPT-6 Luna",
                                  description: "", supportedEfforts: [], defaultEffort: "", isDefault: false, tag: "OpenAI · Work")
        let unavailable = AppleHarnessInspection(models: [HarnessModel(id: "default", displayName: "Apple on-device", description: "",
            supportedEfforts: [], defaultEffort: "", isDefault: true)], unavailableReason: "Enable Apple Intelligence in System Settings, then check again.",
            version: "1", localModelsSupported: true)
        let merged = unavailable.adding(remote: [remote])
        XCTAssertEqual(merged.models.map(\.id), [remote.id], "The on-device model cannot run, so it is not offered")
        XCTAssertNil(merged.unavailableReason)
        XCTAssertEqual(unavailable.adding(remote: []).models.map(\.id), ["default"])
        XCTAssertNotNil(unavailable.adding(remote: []).unavailableReason)

        let available = AppleHarnessInspection(models: unavailable.models, unavailableReason: nil, version: "1", localModelsSupported: true)
        XCTAssertEqual(available.adding(remote: [remote]).models.map(\.id), ["default", remote.id])

        let macOS26 = AppleHarnessInspection(models: unavailable.models, unavailableReason: nil, version: "1", localModelsSupported: false)
        XCTAssertEqual(macOS26.adding(remote: [remote]).models.map(\.id), ["default"], "Custom models need macOS 27")
    }

    func testAddingAnAccountChecksItsKeyWithOneRequest() async throws {
        let openAI = try XCTUnwrap(RemoteProviders.provider(id: "openai"))
        let accepted = StubTransport(responses: [(200, #"{"data":[]}"#)])
        try await openAI.checkKey("sk-good", transport: accepted)
        XCTAssertEqual(accepted.requests.first?.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(accepted.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-good")
        let rejected = StubTransport(responses: [(401, #"{"error":{"message":"Incorrect API key provided"}}"#)])
        do {
            try await openAI.checkKey("sk-bad", transport: rejected)
            XCTFail("A rejected key is reported")
        } catch { XCTAssertEqual(error.localizedDescription, "OpenAI rejected this API key: Incorrect API key provided") }
        // Both gateways list their models without a key, so the check asks for something that needs one.
        for (provider, url) in [("openrouter", "https://openrouter.ai/api/v1/key"), ("vercel", "https://ai-gateway.vercel.sh/v1/credits")] {
            let transport = StubTransport(responses: [(200, "{}")])
            try await XCTUnwrap(RemoteProviders.provider(id: provider)).checkKey("k", transport: transport)
            XCTAssertEqual(transport.requests.first?.url?.absoluteString, url)
        }
    }

    func testOllamaFindsToolModelsOnTheLocalServer() async throws {
        let ollama = try XCTUnwrap(RemoteProviders.provider(id: "ollama"))
        XCTAssertEqual(ollama.displayName, "Ollama")
        XCTAssertEqual(ollama.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertFalse(ollama.requiresKey)
        let transport = StubTransport(responses: [
            (200, #"{"models":[{"name":"qwen3:8b"},{"name":"gemma3:12b"},{"name":"llava:7b"}]}"#),
            (200, #"{"capabilities":["completion","tools","thinking"],"model_info":{"general.architecture":"qwen3","qwen3.context_length":40960},"parameters":"temperature 0.6\nnum_ctx 16384"}"#),
            (200, #"{"capabilities":["completion","tools","vision"],"model_info":{"general.architecture":"gemma3","gemma3.context_length":131072}}"#),
            (200, #"{"capabilities":["completion","vision"],"model_info":{"general.architecture":"llama","llama.context_length":4096}}"#)
        ])
        let models = try await ollama.findModels(transport: transport)
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, ["http://localhost:11434/api/tags"]
                       + Array(repeating: "http://localhost:11434/api/show", count: 3))
        let shown = try XCTUnwrap(transport.requests[1].httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(shown["model"] as? String, "qwen3:8b")
        XCTAssertEqual(models.map(\.id), ["qwen3:8b", "gemma3:12b"], "A bot works through tools")
        XCTAssertEqual(models.map(\.displayName), ["qwen3:8b", "gemma3:12b"])
        XCTAssertEqual(models[0].contextSize, 16_384, "A context set on the model is the one Ollama runs it with")
        XCTAssertEqual(models[1].contextSize, 32_768, "Otherwise no more than Ollama's default on a Mac with enough memory")
        XCTAssertEqual(models.map(\.supportsImages), [false, true])
        XCTAssertEqual(models[0].efforts.map(\.id), ["none", "low", "medium", "high"])
        XCTAssertTrue(models[1].efforts.isEmpty)
        for model in models { XCTAssertTrue(ollama.api(for: model) is OllamaChatAPI, model.id) }
    }

    func testOllamaAccountsNeedNoKeyAndOfferTheModelsFound() throws {
        let qwen = RemoteModelInfo(id: "qwen3:8b", displayName: "qwen3:8b", contextSize: 16_384, maximumOutputTokens: 4_096,
                                   supportsImages: false, efforts: [], defaultEffort: "")
        let local = try store.add(providerID: "ollama", name: "This Mac", apiKey: "", models: [qwen])
        XCTAssertNil(try secrets.read(local.id), "Nothing goes in the Keychain")
        XCTAssertEqual(try store.apiKey(for: local.id), "")
        XCTAssertThrowsError(try store.setModel("llama3.3:70b", enabled: true, account: local.id))
        try store.setModel("qwen3:8b", enabled: true, account: local.id)
        let id = RemoteModelID(providerID: "ollama", accountID: local.id, modelID: "qwen3:8b")
        XCTAssertEqual(try store.harnessModels().map(\.id), [id.rawValue])
        XCTAssertEqual(try store.harnessModels().first?.tag, "Ollama · This Mac")
        XCTAssertNil(id.model, "Only the app knows which models an Ollama server has")
        XCTAssertTrue(id.isOffered)
        XCTAssertFalse(RemoteModelID(providerID: "openai", accountID: local.id, modelID: "gpt-3.5-turbo").isOffered)
        let access = try store.access(for: id)
        XCTAssertEqual(access.apiKey, "")
        XCTAssertEqual(access.model, qwen, "The bot learns the model's limits from the app")

        let gemma = RemoteModelInfo(id: "gemma3:12b", displayName: "gemma3:12b", contextSize: 32_768, maximumOutputTokens: 8_192,
                                    supportsImages: true, efforts: [], defaultEffort: "")
        try store.setFoundModels([gemma], account: local.id)
        let reloaded = RemoteModelAccountStore(repository: root, secrets: secrets)
        XCTAssertEqual(try reloaded.accounts().first?.models, [gemma])
        XCTAssertTrue(try reloaded.harnessModels().isEmpty, "A model gone from the server is not offered")
        XCTAssertThrowsError(try reloaded.access(for: id))

        let work = try store.add(providerID: "openai", name: "Work", apiKey: "sk-work")
        let luna = RemoteModelID(providerID: "openai", accountID: work.id, modelID: "gpt-6-luna")
        XCTAssertEqual(try store.access(for: luna).apiKey, "sk-work")
        XCTAssertNil(try store.access(for: luna).model, "Bots use Noodle's own list for listed providers")
    }

    func testCustomServersAreCheckedAndSuggestModelsAtTheirOwnAddress() async throws {
        XCTAssertEqual(RemoteProviders.provider(id: "custom")?.displayName, "Custom")
        let lab = try XCTUnwrap(RemoteProviders.provider(id: "custom", baseURL: URL(string: "http://lab.local:8000/v1")))
        XCTAssertFalse(lab.requiresKey)
        XCTAssertTrue(lab.describesModels)
        XCTAssertTrue(lab.api(for: RemoteModelInfo.custom(id: "m")) is ChatCompletionsAPI)

        let listed = StubTransport(responses: [(200, #"{"data":[{"id":"llama-3.3-70b"},{"id":"qwen3:8b"},{"id":"not valid"}]}"#)])
        let suggested = try await lab.findModels(transport: listed)
        XCTAssertEqual(listed.requests.first?.url?.absoluteString, "http://lab.local:8000/v1/models")
        XCTAssertEqual(suggested.map(\.id), ["llama-3.3-70b", "qwen3:8b"])
        XCTAssertEqual(suggested.first, .custom(id: "llama-3.3-70b"), "Details start from defaults the person adjusts")

        let keyed = StubTransport(responses: [(200, "{}")])
        try await lab.checkKey("sk-lab", transport: keyed)
        XCTAssertEqual(keyed.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-lab")
        let open = StubTransport(responses: [(404, "Not Found")])
        try await lab.checkKey("", transport: open)
        XCTAssertNil(open.requests.first?.value(forHTTPHeaderField: "Authorization"))
        let rejected = StubTransport(responses: [(401, #"{"error":{"message":"Invalid key"}}"#)])
        do {
            try await lab.checkKey("sk-bad", transport: rejected)
            XCTFail("A rejected key is reported")
        } catch { XCTAssertEqual(error.localizedDescription, "lab.local rejected this API key: Invalid key") }
        XCTAssertNil(RemoteProviders.provider(id: "custom", baseURL: nil), "A custom account cannot be reached without its address")
    }

    func testCustomAccountsKeepTheirAddressKeyAndDescribedModels() throws {
        let url = try XCTUnwrap(URL(string: "https://llm.example.com/v1"))
        for invalid in ["", "llm.example.com", "ftp://llm.example.com", "https://"] {
            XCTAssertThrowsError(try store.add(providerID: "custom", name: "Lab", apiKey: "", baseURL: URL(string: invalid)), invalid)
        }
        let lab = try store.add(providerID: "custom", name: "Lab", apiKey: "", baseURL: url)
        XCTAssertNil(try secrets.read(lab.id))
        XCTAssertTrue(lab.models.isEmpty, "Nothing is offered until the person adds a model")
        XCTAssertTrue(try store.harnessModels().isEmpty)

        let llama = RemoteModelInfo(id: "llama-3.3-70b", displayName: "Llama 3.3 70B", contextSize: 131_072, maximumOutputTokens: 8_192,
                                    supportsImages: false, efforts: RemoteModelInfo.efforts("low", "high"), defaultEffort: "high")
        try store.saveModel(llama, account: lab.id)
        let id = RemoteModelID(providerID: "custom", accountID: lab.id, modelID: "llama-3.3-70b")
        XCTAssertEqual(try store.harnessModels().map(\.id), [id.rawValue], "An added model is offered")
        XCTAssertEqual(try store.harnessModels().first?.tag, "Custom · Lab")
        XCTAssertTrue(id.isOffered)
        var access = try store.access(for: id)
        XCTAssertEqual(access.model, llama)
        XCTAssertEqual(access.baseURL, url)
        XCTAssertEqual(access.apiKey, "")
        XCTAssertEqual(try RemoteModelAccess(access.wire), access, "The address travels to the bot with the key")

        for invalid in [RemoteModelInfo.custom(id: "has space"), RemoteModelInfo.custom(id: "m", contextSize: 0),
                        RemoteModelInfo.custom(id: "m", maximumOutputTokens: 0),
                        RemoteModelInfo(id: "m", displayName: "M", contextSize: 8_192, maximumOutputTokens: 1_024, supportsImages: false,
                                        efforts: RemoteModelInfo.efforts("low"), defaultEffort: "high")] {
            XCTAssertThrowsError(try store.saveModel(invalid, account: lab.id), invalid.id)
        }
        XCTAssertThrowsError(try store.saveModel(.custom(id: "llama-3.3-70b"), account: lab.id), "Adding the same model twice")
        let edited = RemoteModelInfo.custom(id: "llama-3.3-70b", contextSize: 65_536)
        try store.saveModel(edited, replacing: "llama-3.3-70b", account: lab.id)
        XCTAssertEqual(try store.access(for: id).model, edited)
        XCTAssertThrowsError(try store.saveModel(llama, account: try store.add(providerID: "openai", name: "Work", apiKey: "sk").id),
                             "Listed providers describe their own models")

        try store.replaceKey(lab.id, with: "sk-lab")
        XCTAssertEqual(try store.access(for: id).apiKey, "sk-lab")
        try store.replaceKey(lab.id, with: "")
        XCTAssertNil(try secrets.read(lab.id), "A custom server's key can be taken away")

        let reloaded = RemoteModelAccountStore(repository: root, secrets: secrets)
        XCTAssertEqual(try reloaded.account(lab.id).baseURL, url)
        try reloaded.removeModel("llama-3.3-70b", account: lab.id)
        XCTAssertTrue(try reloaded.harnessModels().isEmpty)
        access = try reloaded.access(for: RemoteModelID(providerID: "openai", accountID: try reloaded.accounts().first { $0.name == "Work" }!.id,
                                                        modelID: "gpt-6-luna"))
        XCTAssertNil(access.baseURL, "Listed providers keep their own address")
    }

    func testHarnessModelsSavedBeforeTagsStillDecode() throws {
        let data = Data(#"{"id":"x","displayName":"X","description":"","supportedEfforts":[],"defaultEffort":"","isDefault":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(HarnessModel.self, from: data).tag)
    }
}

final class MemoryRemoteModelSecrets: RemoteModelSecrets, @unchecked Sendable {
    private var values: [UUID: String] = [:]
    func read(_ account: UUID) throws -> String? { values[account] }
    func write(_ key: String, account: UUID) throws { values[account] = key }
    func delete(_ account: UUID) throws { values[account] = nil }
}
