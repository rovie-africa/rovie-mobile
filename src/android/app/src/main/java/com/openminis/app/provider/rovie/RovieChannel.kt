package com.openminis.app.provider.rovie

import android.content.Context
import com.openminis.app.data.model.LLMModel
import com.openminis.app.provider.ModelsDevApi
import com.openminis.app.provider.openai.OpenAIModelsApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * [RovieChannel] Dedicated integration channel for Rovie Route on Android.
 *
 * Routes requests through Rovie Route's LiteLLM proxy (https://api.rovie.africa/v1)
 * with local currency budget tracking and unified model access across Africa.
 *
 * Stamps:
 * - `x-litellm-tags: rovie-mobile`
 * - `x-litellm-session-id: <conversation-session-id>`
 */
object RovieChannel {

    const val TAG_HEADER = "x-litellm-tags"
    const val TAG_VALUE = "rovie-mobile"
    const val SESSION_HEADER = "x-litellm-session-id"

    const val DEFAULT_BASE_URL = "https://api.rovie.africa/v1"
    const val DEFAULT_PORTAL_URL = "https://route.rovie.africa"
    const val DEFAULT_CATALOG_URL = "https://rovie-account-service.fly.dev/models"

    private val SERVICE_HOSTS = listOf(
        "api.rovie.africa",
        "route.rovie.africa",
        "rovie.africa"
    )

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    /**
     * Matches whether a configured base URL belongs to Rovie Route.
     */
    fun looksLikeRovieBaseURL(base: String?): Boolean {
        val raw = base?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val withScheme = if (raw.contains("://")) raw else "https://$raw"
        val host = withScheme.toHttpUrlOrNull()?.host?.lowercase() ?: return false
        return SERVICE_HOSTS.any { host == it || host.endsWith(".$it") }
    }

    /**
     * Build LiteLLM tracking and session headers for Rovie Route requests.
     */
    fun headersFor(baseUrl: String?, sessionId: String?): Map<String, String> {
        if (!looksLikeRovieBaseURL(baseUrl)) return emptyMap()
        val headers = mutableMapOf(TAG_HEADER to TAG_VALUE)
        val sid = sessionId?.trim()
        if (!sid.isNullOrEmpty()) {
            headers[SESSION_HEADER] = sid
        }
        return headers
    }

    const val DEFAULT_MODEL_ID = "claude-sonnet-5-5"

    val defaultFreeModelIds: Set<String> = setOf(
        "rovie-free",
        "gemini-3.5-flash-lite",
        "deepseek-v4-flash",
        "mistral-small",
        "qwen3.8-flash",
        "llama-3.3-70b-groq",
        "qwen-3-32b-cerebras",
        "deepseek-v3-together",
        "deepseek-v3-fireworks"
    )

    @Volatile
    private var dynamicFreeModelIds: Set<String> = defaultFreeModelIds

    val freeModelIds: Set<String>
        get() = dynamicFreeModelIds

    fun isFreeModel(modelId: String): Boolean = freeModelIds.contains(modelId)

    fun cleanDisplayName(name: String): String {
        var result = name
        if (result.endsWith(" (Free)")) {
            result = result.dropLast(" (Free)".length)
        }
        if (result.endsWith(" (Auto)")) {
            result = result.dropLast(" (Auto)".length)
        }
        return result
    }

    val bootstrapModels: List<LLMModel> = listOf(
        LLMModel(id = "rovie-free", displayName = "Rovie Free", provider = "Rovie"),
        LLMModel(id = DEFAULT_MODEL_ID, displayName = "Claude Sonnet 5.5", provider = "Anthropic")
    )

    private fun normalizeProviderLabel(raw: String?): String {
        return when ((raw ?: "").lowercase()) {
            "anthropic" -> "Anthropic"
            "openai" -> "OpenAI"
            "google" -> "Google"
            "deepseek" -> "DeepSeek"
            "xai" -> "xAI"
            "moonshotai", "moonshot" -> "Moonshot"
            "alibaba", "qwen" -> "Alibaba"
            "mistral" -> "Mistral"
            "cohere" -> "Cohere"
            "groq" -> "Groq"
            "cerebras" -> "Cerebras"
            "togetherai", "together" -> "Together"
            "fireworks" -> "Fireworks"
            "rovie" -> "Rovie"
            else -> {
                if (raw.isNullOrEmpty()) "OpenAI"
                else raw.replaceFirstChar { it.uppercase() }
            }
        }
    }

    /**
     * Fetch the live Rovie Route model catalog dynamically:
     * merges rich metadata from `https://rovie-account-service.fly.dev/models`
     * with gateway `/v1/models`.
     */
    suspend fun fetchModels(
        apiKey: String?,
        baseURL: String?,
        context: Context? = null,
        forceRefresh: Boolean = false,
        customUserAgent: String? = null,
        netTag: String? = null
    ): List<LLMModel> = withContext(Dispatchers.IO) {
        coroutineScope {
            val catalogDeferred = async { fetchPublicCatalogModels() }
            val gatewayDeferred = async {
                val key = apiKey?.trim()
                if (key.isNullOrEmpty()) {
                    emptyList()
                } else {
                    try {
                        OpenAIModelsApi.fetchModelsDetailed(
                            apiKey = key,
                            baseURL = baseURL ?: DEFAULT_BASE_URL,
                            context = context,
                            forceRefresh = forceRefresh,
                            customUserAgent = customUserAgent,
                            netTag = netTag
                        ).models
                    } catch (e: Exception) {
                        emptyList()
                    }
                }
            }

            val catalogModels = catalogDeferred.await()
            val gatewayModels = gatewayDeferred.await()

            if (catalogModels.isEmpty() && gatewayModels.isEmpty()) {
                return@coroutineScope bootstrapModels
            }

            val mergedById = LinkedHashMap<String, LLMModel>()
            for (m in catalogModels) {
                mergedById[m.id] = m
            }

            for (gm in gatewayModels) {
                val existing = mergedById[gm.id]
                if (existing != null) {
                    val merged = existing.copy(
                        contextWindow = existing.contextWindow ?: gm.contextWindow,
                        maxOutputTokens = existing.maxOutputTokens ?: gm.maxOutputTokens,
                        supportsReasoning = existing.supportsReasoning ?: gm.supportsReasoning,
                        limitsReportedByEndpoint = existing.limitsReportedByEndpoint ?: gm.limitsReportedByEndpoint
                    )
                    mergedById[gm.id] = merged
                } else {
                    mergedById[gm.id] = gm
                }
            }

            val combined = mergedById.values.toList()
            ModelsDevApi.enrichModels(combined)
        }
    }

    private suspend fun fetchPublicCatalogModels(): List<LLMModel> = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(DEFAULT_CATALOG_URL)
            .header("Accept", "application/json")
            .get()
            .build()

        try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext emptyList()
                val body = response.body?.string() ?: return@withContext emptyList()
                val root = JSONObject(body)
                val items = root.optJSONArray("models") ?: return@withContext emptyList()

                val discoveredFreeIds = mutableSetOf("rovie-free")
                val result = mutableListOf<LLMModel>()

                for (i in 0 until items.length()) {
                    val item = items.optJSONObject(i) ?: continue
                    val id = item.optString("litellmModelName").ifEmpty { item.optString("id") }
                    if (id.isEmpty()) continue

                    val rawName = item.optString("name").ifEmpty { id }
                    val cost = item.optJSONObject("cost")
                    val isZeroCost = cost != null && cost.optDouble("input", -1.0) == 0.0 && cost.optDouble("output", -1.0) == 0.0
                    val isFree = item.optBoolean("free", false) || isZeroCost
                    if (isFree) {
                        discoveredFreeIds.add(id)
                    }

                    val displayName = cleanDisplayName(rawName)
                    val provider = normalizeProviderLabel(item.optString("provider", ""))

                    val inMods = mutableListOf<String>()
                    val outMods = mutableListOf<String>()
                    val mods = item.optJSONObject("modalities")
                    if (mods != null) {
                        val inArr = mods.optJSONArray("input")
                        if (inArr != null) {
                            for (j in 0 until inArr.length()) inMods.add(inArr.optString(j))
                        }
                        val outArr = mods.optJSONArray("output")
                        if (outArr != null) {
                            for (j in 0 until outArr.length()) outMods.add(outArr.optString(j))
                        }
                    }

                    val limit = item.optJSONObject("limit")
                    val contextWindow = if (limit != null && limit.has("context")) limit.optInt("context") else null
                    val maxOutput = if (limit != null && limit.has("output")) limit.optInt("output") else null
                    val supportsReasoning = if (item.has("reasoning")) item.optBoolean("reasoning") else null

                    result.add(
                        LLMModel(
                            id = id,
                            displayName = displayName,
                            provider = provider,
                            contextWindow = contextWindow,
                            maxOutputTokens = maxOutput,
                            limitsReportedByEndpoint = if (contextWindow != null || maxOutput != null) true else null,
                            supportsReasoning = supportsReasoning,
                            inputModalities = inMods.ifEmpty { null },
                            outputModalities = outMods.ifEmpty { null }
                        )
                    )
                }

                if (discoveredFreeIds.isNotEmpty()) {
                    dynamicFreeModelIds = discoveredFreeIds
                }
                result
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
}
