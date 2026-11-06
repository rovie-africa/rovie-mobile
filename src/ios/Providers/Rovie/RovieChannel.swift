import Foundation

extension Notification.Name {
    static let rovieAuthCompleted = Notification.Name("rovieAuthCompleted")
}

/// [RovieChannel] Dedicated integration channel for Rovie Route.
///
/// Routes requests through Rovie Route's LiteLLM proxy (https://api.rovie.africa/v1)
/// with local currency budget tracking and unified model access across Africa.
///
/// Stamps:
/// - `x-litellm-tags: rovie-mobile`
/// - `x-litellm-session-id: <conversation-session-id>`
enum RovieChannel {

    /// LiteLLM routing and tracking headers
    static let sessionHeader = "x-litellm-session-id"
    static let tagHeader = "x-litellm-tags"
    static let tagValue = "rovie-mobile"

    /// Default Rovie Route gateway and wallet portal
    static let defaultBaseURL = "https://api.rovie.africa/v1"
    static let defaultPortalURL = "https://route.rovie.africa"
    static let defaultCatalogURL = "https://rovie-account-service.fly.dev/models"

    private static let serviceHosts = [
        "api.rovie.africa",
        "route.rovie.africa",
        "rovie.africa"
    ]

    /// Matches whether a configured base URL belongs to Rovie Route
    static func looksLikeRovieBaseURL(_ base: String?) -> Bool {
        guard let raw = base?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        let withScheme = raw.contains("://") ? raw : "https://" + raw
        guard let host = URLComponents(string: withScheme)?.host?.lowercased(),
              !host.isEmpty else { return false }
        return serviceHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    /// Default model selection for onboarding
    static let defaultModelId = "claude-sonnet-5-5"

    private static let freeModelsDefaultsKey = "rovie.freeModelIds"

    /// Fallback set of free model IDs used before the first catalog fetch completes.
    /// Updated dynamically from `defaultCatalogURL` (`free: true` / zero cost).
    static let defaultFreeModelIds: Set<String> = [
        "rovie-free",
        "gemini-3.5-flash-lite",
        "deepseek-v4-flash",
        "mistral-small",
        "qwen3.8-flash",
        "llama-3.3-70b-groq",
        "qwen-3-32b-cerebras",
        "deepseek-v3-together",
        "deepseek-v3-fireworks"
    ]

    static var freeModelIds: Set<String> {
        if let saved = UserDefaults.standard.stringArray(forKey: freeModelsDefaultsKey), !saved.isEmpty {
            return Set(saved).union(["rovie-free"])
        }
        return defaultFreeModelIds
    }

    static func isFreeModel(_ modelId: String) -> Bool {
        freeModelIds.contains(modelId)
    }

    static func cleanDisplayName(_ name: String) -> String {
        var result = name
        if result.hasSuffix(" (Free)") {
            result = String(result.dropLast(" (Free)".count))
        }
        if result.hasSuffix(" (Auto)") {
            result = String(result.dropLast(" (Auto)".count))
        }
        return result
    }

    static func sortFreeEntries(_ entries: [ModelEntry]) -> [ModelEntry] {
        entries.sorted { a, b in
            let aIsAuto = a.baseModel.id == "rovie-free"
            let bIsAuto = b.baseModel.id == "rovie-free"
            if aIsAuto != bIsAuto { return aIsAuto }
            return false
        }
    }

    /// Minimal offline-only bootstrap seed used ONLY if the device has no network
    /// connection before the first `/models` fetch completes. All real models
    /// are discovered dynamically from Rovie Route (`defaultCatalogURL` + `/v1/models`).
    static let bootstrapModels: [LLMModel] = [
        LLMModel(id: "rovie-free", displayName: "Rovie Free", provider: "Rovie"),
        LLMModel(id: defaultModelId, displayName: "Claude Sonnet 5.5", provider: "Anthropic")
    ]

    private static func normalizeProviderLabel(_ raw: String?) -> String {
        switch (raw ?? "").lowercased() {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "google": return "Google"
        case "deepseek": return "DeepSeek"
        case "xai": return "xAI"
        case "moonshotai", "moonshot": return "Moonshot"
        case "alibaba", "qwen": return "Alibaba"
        case "mistral": return "Mistral"
        case "cohere": return "Cohere"
        case "groq": return "Groq"
        case "cerebras": return "Cerebras"
        case "togetherai", "together": return "Together"
        case "fireworks": return "Fireworks"
        case "rovie": return "Rovie"
        default:
            guard let raw, !raw.isEmpty else { return "OpenAI" }
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Fetch the live Rovie Route model catalog dynamically from the server:
    /// combines rich metadata (`name`, `provider`, `free`, `cost`, `limit`, `reasoning`,
    /// `modalities`) from `https://rovie-account-service.fly.dev/models` with
    /// the gateway's `/v1/models` list. No hardcoded model catalog required.
    static func fetchModels(
        apiKey: String?,
        baseURL: String?,
        appendV1Suffix: Bool = true,
        forceRefresh: Bool = false,
        userAgent: String? = nil
    ) async throws -> [LLMModel] {
        async let catalogResult: [LLMModel] = fetchPublicCatalogModels()
        async let gatewayResult: Result<[LLMModel], Error> = {
            guard let key = apiKey, !key.isEmpty else {
                return .success([])
            }
            do {
                let models = try await OpenAIModelsAPI.fetchModels(
                    apiKey: key,
                    baseURL: baseURL ?? defaultBaseURL,
                    appendV1Suffix: appendV1Suffix,
                    forceRefresh: forceRefresh,
                    userAgent: userAgent
                )
                return .success(models)
            } catch {
                return .failure(error)
            }
        }()

        let catalogModels = await catalogResult
        let gatewayOutcome = await gatewayResult

        var gatewayModels: [LLMModel] = []
        var gatewayError: Error?
        switch gatewayOutcome {
        case .success(let list):
            gatewayModels = list
        case .failure(let err):
            gatewayError = err
        }

        if catalogModels.isEmpty && gatewayModels.isEmpty {
            if let gatewayError {
                throw gatewayError
            }
            return bootstrapModels
        }

        // Merge: catalogModels carry authoritative server metadata (name, provider,
        // free/cost, limits, modalities); gatewayModels add any extra models from /v1/models.
        var mergedById: [String: LLMModel] = [:]
        var orderedIds: [String] = []

        for m in catalogModels {
            mergedById[m.id] = m
            orderedIds.append(m.id)
        }

        for gm in gatewayModels {
            if var existing = mergedById[gm.id] {
                if existing.contextWindow == nil { existing.contextWindow = gm.contextWindow }
                if existing.maxOutputTokens == nil { existing.maxOutputTokens = gm.maxOutputTokens }
                if existing.supportsReasoning == nil { existing.supportsReasoning = gm.supportsReasoning }
                if existing.modalityOverride == nil { existing.modalityOverride = gm.modalityOverride }
                mergedById[gm.id] = existing
            } else {
                mergedById[gm.id] = gm
                orderedIds.append(gm.id)
            }
        }

        let combined = orderedIds.compactMap { mergedById[$0] }
        return ModelsDevAPI.enrichModels(combined)
    }

    private static func fetchPublicCatalogModels() async -> [LLMModel] {
        guard let url = URL(string: defaultCatalogURL) else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["models"] as? [[String: Any]] else {
            return []
        }

        var discoveredFreeIds = Set<String>(["rovie-free"])

        let models = items.compactMap { item -> LLMModel? in
            guard let id = (item["litellmModelName"] as? String) ?? (item["id"] as? String),
                  !id.isEmpty else { return nil }

            let rawName = (item["name"] as? String) ?? id
            let cost = item["cost"] as? [String: Any]
            let isZeroCost = (cost?["input"] as? Double == 0) && (cost?["output"] as? Double == 0)
            let isFree = (item["free"] as? Bool) == true || isZeroCost
            if isFree {
                discoveredFreeIds.insert(id)
            }
            let displayName = cleanDisplayName(rawName)

            let provider = normalizeProviderLabel(item["provider"] as? String)

            var modality: ModelModality = [.textInput, .textOutput]
            if let mods = item["modalities"] as? [String: Any] {
                if let inputs = mods["input"] as? [String] {
                    if inputs.contains("image") { modality.insert(.imageInput) }
                    if inputs.contains("pdf") { modality.insert(.pdfInput) }
                    if inputs.contains("audio") { modality.insert(.audioInput) }
                    if inputs.contains("video") { modality.insert(.videoInput) }
                }
                if let outputs = mods["output"] as? [String] {
                    if outputs.contains("image") { modality.insert(.imageOutput) }
                    if outputs.contains("audio") || outputs.contains("speech") { modality.insert(.audioOutput) }
                    if outputs.contains("video") { modality.insert(.videoOutput) }
                }
            }

            let limit = item["limit"] as? [String: Any]
            let contextWindow = limit?["context"] as? Int
            let maxOutput = limit?["output"] as? Int
            let supportsReasoning = item["reasoning"] as? Bool

            var model = LLMModel(
                id: id,
                displayName: displayName,
                provider: provider,
                modalityOverride: modality,
                contextWindow: contextWindow,
                maxOutputTokens: maxOutput,
                supportsReasoning: supportsReasoning
            )
            if contextWindow != nil || maxOutput != nil {
                model.limitsReportedByEndpoint = true
            }
            return model
        }

        if !discoveredFreeIds.isEmpty {
            UserDefaults.standard.set(Array(discoveredFreeIds), forKey: freeModelsDefaultsKey)
        }
        return models
    }

    /// Attach Rovie tags and dynamic session ID to an OpenAIProvider instance
    @discardableResult
    static func attach(to provider: OpenAIProvider,
                       resolveSessionId: @escaping @Sendable () -> String?) -> OpenAIProvider {
        let existing = provider.perRequestHeaders
        provider.perRequestHeaders = { body in
            var headers = existing?(body) ?? [:]
            
            // LiteLLM analytics and rate-limiting tag
            headers[tagHeader] = tagValue
            
            // Conversation session ID for cache & trace correlation
            if headers[sessionHeader] == nil,
               let raw = resolveSessionId(),
               let sid = OpenCodeChannel.normalizedSessionId(raw) {
                headers[sessionHeader] = sid
            }
            return headers
        }
        return provider
    }

    /// Seamless 1-tap configuration with a Rovie Route API key
    @MainActor
    static func configureWithApiKey(_ key: String) {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return }

        let store = ProviderConfigStore.shared

        // Find or create Rovie Route instance
        let instance: ProviderInstance
        if let existing = store.instances.first(where: { looksLikeRovieBaseURL($0.customBaseURL) }) {
            var updated = existing
            updated.isEnabled = true
            store.updateInstance(updated)
            instance = updated
        } else {
            let newInst = ProviderInstance(
                label: "Rovie Route",
                providerType: .openAI,
                credentialType: .apiKey,
                customBaseURL: defaultBaseURL,
                appendV1Suffix: true
            )
            store.addInstance(newInst)
            instance = newInst
        }

        // Store API key in Keychain
        ProviderKeychainHelper.saveAPIKey(cleanKey, instanceId: instance.id)

        // Seed minimal bootstrap only if completely empty before first server fetch
        if store.entries(for: instance.id).isEmpty {
            for model in bootstrapModels {
                store.addEntry(ModelEntry(providerInstanceId: instance.id, model: model))
            }
        }

        // Sync all visible Rovie Route entries into "Rovie Default" group
        store.syncRovieDefaultGroup(for: instance.id)

        // Force store notification so all SwiftUI observers immediately redraw
        store.objectWillChange.send()
        NotificationCenter.default.post(name: .rovieAuthCompleted, object: nil, userInfo: ["apiKey": cleanKey])

        // Kick off wallet balance check and live server catalog discovery in background
        Task {
            await RovieWalletClient.shared.refreshBalance(apiKey: cleanKey)
            await store.refreshModels(for: instance)
            store.syncRovieDefaultGroup(for: instance.id)
        }
    }
}
