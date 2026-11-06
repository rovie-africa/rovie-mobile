package com.openminis.app.provider.rovie

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

@Serializable
data class RovieWalletBalance(
    val availableUsd: Double,
    val spendUsd: Double,
    val maxBudgetUsd: Double? = null,
    val localCurrency: String,
    val availableLocal: Double,
    val spendLocal: Double,
    val maxBudgetLocal: Double? = null,
    val country: String,
) {
    val formattedLocalAvailable: String
        get() {
            val symbol = when (localCurrency.uppercase()) {
                "NGN" -> "₦"
                "UGX" -> "USh "
                "GHS" -> "GH₵"
                "KES" -> "KSh "
                "ZAR" -> "R "
                else -> "$localCurrency "
            }
            return "$symbol%,.0f".format(availableLocal)
        }
}

/**
 * Client for monitoring Rovie Route wallet balance on Android.
 */
object RovieWalletClient {
    private val client = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .build()

    private val _currentBalance = MutableStateFlow<RovieWalletBalance?>(null)
    val currentBalance: StateFlow<RovieWalletBalance?> = _currentBalance.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    suspend fun refreshBalance(apiKey: String) = withContext(Dispatchers.IO) {
        val cleanKey = apiKey.trim()
        if (cleanKey.isEmpty()) {
            _currentBalance.value = null
            return@withContext
        }

        _isLoading.value = true
        _lastError.value = null

        val url = "${RovieChannel.DEFAULT_PORTAL_URL}/key/balance"
        val request = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .header("Authorization", "Bearer $cleanKey")
            .get()
            .build()

        try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    _isLoading.value = false
                    _lastError.value = "HTTP ${response.code}"
                    return@withContext
                }
                val body = response.body?.string() ?: return@withContext
                val json = JSONObject(body)
                val balance = RovieWalletBalance(
                    availableUsd = json.optDouble("availableUsd", 0.0),
                    spendUsd = json.optDouble("spendUsd", 0.0),
                    maxBudgetUsd = if (json.has("maxBudgetUsd") && !json.isNull("maxBudgetUsd")) json.optDouble("maxBudgetUsd") else null,
                    localCurrency = json.optString("localCurrency", "USD"),
                    availableLocal = json.optDouble("availableLocal", 0.0),
                    spendLocal = json.optDouble("spendLocal", 0.0),
                    maxBudgetLocal = if (json.has("maxBudgetLocal") && !json.isNull("maxBudgetLocal")) json.optDouble("maxBudgetLocal") else null,
                    country = json.optString("country", "")
                )
                _currentBalance.value = balance
                _isLoading.value = false
            }
        } catch (e: Exception) {
            _isLoading.value = false
            _lastError.value = e.message
        }
    }
}
