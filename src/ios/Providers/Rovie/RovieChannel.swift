import Foundation

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

    /// Curated model list mirroring rovie-code
    static let curatedModels: [(id: String, displayName: String, provider: String)] = [
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", "anthropic"),
        ("claude-haiku-5-5", "Claude Haiku 5.5", "anthropic"),
        ("gpt-6.1-sol", "GPT-6.1 Sol", "openai"),
        ("gpt-6-astra", "GPT-6 Astra", "openai"),
        ("gemini-3.8-flash", "Gemini 3.8 Flash", "google"),
        ("gemini-3.7-flash", "Gemini 3.7 Flash", "google"),
        ("deepseek-v4-flash", "DeepSeek V4 Flash", "deepseek"),
        ("deepseek-v4-pro", "DeepSeek V4 Pro", "deepseek"),
        ("qwen3.8-max", "Qwen 3.8 Max", "alibaba"),
        ("grok-4.7", "Grok 4.7", "xai")
    ]

    /// Default model selection for onboarding
    static let defaultModelId = "claude-sonnet-5-5"

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
            instance = existing
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

        // Ensure model entries exist
        let existingEntries = store.entries(for: instance.id)
        if existingEntries.isEmpty {
            for model in curatedModels {
                let entry = ModelEntry(
                    providerInstanceId: instance.id,
                    model: LLMModel(
                        id: model.id,
                        displayName: model.displayName,
                        provider: "openai"
                    )
                )
                store.addEntry(entry)
            }
        }

        // Ensure at least one ModelGroup exists so onboarding transitions immediately to chat
        if store.modelGroups.isEmpty {
            let entryIds = store.entries(for: instance.id).map { $0.id }
            let group = ModelGroup(
                name: "Rovie Default",
                memberEntryIds: entryIds.isEmpty ? ["\(instance.id)/\(defaultModelId)"] : entryIds
            )
            store.addGroup(group)
        }

        // Kick off wallet balance check and catalog discovery in background
        Task {
            await RovieWalletClient.shared.refreshBalance(apiKey: cleanKey)
            await store.refreshModels(for: instance)
        }
    }
}
