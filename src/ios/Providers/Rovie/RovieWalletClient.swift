import Foundation
import Combine

/// [RovieWalletBalance] Decoded wallet budget state from Rovie Route
struct RovieWalletBalance: Codable, Sendable, Equatable {
    let availableUsd: Double
    let spendUsd: Double
    let maxBudgetUsd: Double?
    let localCurrency: String
    let availableLocal: Double
    let spendLocal: Double
    let maxBudgetLocal: Double?
    let country: String?

    enum CodingKeys: String, CodingKey {
        case availableUsd
        case spendUsd
        case maxBudgetUsd
        case localCurrency
        case currency
        case availableLocal
        case spendLocal
        case maxBudgetLocal
        case country
    }

    init(
        availableUsd: Double,
        spendUsd: Double,
        maxBudgetUsd: Double? = nil,
        localCurrency: String,
        availableLocal: Double,
        spendLocal: Double,
        maxBudgetLocal: Double? = nil,
        country: String? = nil
    ) {
        self.availableUsd = availableUsd
        self.spendUsd = spendUsd
        self.maxBudgetUsd = maxBudgetUsd
        self.localCurrency = localCurrency.uppercased()
        self.availableLocal = availableLocal
        self.spendLocal = spendLocal
        self.maxBudgetLocal = maxBudgetLocal
        self.country = country
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func decodeDouble(_ key: CodingKeys) -> Double? {
            if let d = try? container.decodeIfPresent(Double.self, forKey: key) { return d }
            if let i = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
            if let s = try? container.decodeIfPresent(String.self, forKey: key), let d = Double(s) { return d }
            return nil
        }

        self.availableUsd = decodeDouble(.availableUsd) ?? 0
        self.spendUsd = decodeDouble(.spendUsd) ?? 0
        self.maxBudgetUsd = decodeDouble(.maxBudgetUsd)

        let rawCurrency = (try? container.decodeIfPresent(String.self, forKey: .localCurrency))
            ?? (try? container.decodeIfPresent(String.self, forKey: .currency))
            ?? RovieWalletBalance.defaultCurrencyCode
        let cleaned = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.localCurrency = cleaned.isEmpty ? RovieWalletBalance.defaultCurrencyCode : cleaned

        self.availableLocal = decodeDouble(.availableLocal) ?? 0
        self.spendLocal = decodeDouble(.spendLocal) ?? 0
        self.maxBudgetLocal = decodeDouble(.maxBudgetLocal)
        self.country = try? container.decodeIfPresent(String.self, forKey: .country)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(availableUsd, forKey: .availableUsd)
        try container.encode(spendUsd, forKey: .spendUsd)
        try container.encodeIfPresent(maxBudgetUsd, forKey: .maxBudgetUsd)
        try container.encode(localCurrency, forKey: .localCurrency)
        try container.encode(availableLocal, forKey: .availableLocal)
        try container.encode(spendLocal, forKey: .spendLocal)
        try container.encodeIfPresent(maxBudgetLocal, forKey: .maxBudgetLocal)
        try container.encodeIfPresent(country, forKey: .country)
    }

    static var defaultCurrencyCode: String {
        if let code = Locale.current.currency?.identifier, !code.isEmpty {
            let upper = code.uppercased()
            if ["NGN", "KES", "GHS", "UGX", "ZAR", "USD"].contains(upper) {
                return upper
            }
        }
        return "NGN"
    }

    static func zero(currency: String? = nil) -> RovieWalletBalance {
        RovieWalletBalance(
            availableUsd: 0,
            spendUsd: 0,
            maxBudgetUsd: 0,
            localCurrency: currency ?? defaultCurrencyCode,
            availableLocal: 0,
            spendLocal: 0,
            maxBudgetLocal: 0,
            country: nil
        )
    }

    var formattedLocalAvailable: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = localCurrency
        formatter.maximumFractionDigits = (availableLocal.truncatingRemainder(dividingBy: 1) == 0) ? 0 : 2

        switch localCurrency.uppercased() {
        case "NGN":
            formatter.currencySymbol = "₦"
        case "UGX":
            formatter.currencySymbol = "USh "
        case "GHS":
            formatter.currencySymbol = "GH₵"
        case "KES":
            formatter.currencySymbol = "KSh "
        case "ZAR":
            formatter.currencySymbol = "R "
        case "USD":
            formatter.currencySymbol = "$"
        default:
            formatter.currencySymbol = localCurrency + " "
        }

        let symbol = formatter.currencySymbol ?? (localCurrency + " ")
        let val = max(0, availableLocal)
        return formatter.string(from: NSNumber(value: val)) ?? "\(symbol)\(Int(val))"
    }
}

/// [RovieTopUpPreset] Step options in local currency for the interactive top-up slider
struct RovieTopUpPreset: Identifiable, Hashable, Sendable {
    let id: Int
    let amount: Int
    let formatted: String

    static func steps(for currency: String) -> [RovieTopUpPreset] {
        let curr = currency.uppercased()
        let amounts: [Int]
        switch curr {
        case "NGN":
            amounts = [500, 750, 1_000, 1_500, 2_000, 2_500, 3_500, 5_000, 7_500, 10_000, 15_000, 25_000, 50_000]
        case "KES":
            amounts = [50, 100, 150, 200, 250, 350, 500, 750, 1_000, 1_500, 2_500, 5_000]
        case "GHS":
            amounts = [5, 10, 15, 20, 25, 35, 50, 75, 100, 150, 250, 500]
        case "UGX":
            amounts = [2_000, 3_000, 5_000, 7_500, 10_000, 15_000, 20_000, 35_000, 50_000, 100_000]
        case "ZAR":
            amounts = [10, 15, 25, 35, 50, 75, 100, 150, 250, 500, 1_000]
        default:
            amounts = [1, 2, 3, 5, 10, 15, 20, 25, 50, 100]
        }

        let symbol: String
        switch curr {
        case "NGN": symbol = "₦"
        case "KES": symbol = "KSh "
        case "GHS": symbol = "GH₵"
        case "UGX": symbol = "USh "
        case "ZAR": symbol = "R "
        default:    symbol = "$"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal

        return amounts.map { val in
            let str = formatter.string(from: NSNumber(value: val)) ?? "\(val)"
            return RovieTopUpPreset(id: val, amount: val, formatted: "\(symbol)\(str)")
        }
    }

    static func presets(for currency: String) -> [RovieTopUpPreset] {
        steps(for: currency)
    }
}

/// Observable client for monitoring Rovie Route wallet balance
@MainActor
final class RovieWalletClient: ObservableObject {
    static let shared = RovieWalletClient()

    @Published private(set) var currentBalance: RovieWalletBalance?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private init() {
        self.currentBalance = .zero()
    }

    /// Refresh balance from the portal using the user's Rovie Route API key
    func refreshBalance(apiKey: String? = nil, preferredInstanceId: String? = nil) async {
        let key = apiKey ?? RovieChannel.storedAPIKey(preferredInstanceId: preferredInstanceId)
        let cleanKey = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currency = currentBalance?.localCurrency ?? RovieWalletBalance.defaultCurrencyCode

        guard !cleanKey.isEmpty else {
            self.currentBalance = .zero(currency: currency)
            self.isLoading = false
            return
        }

        guard var components = URLComponents(string: "\(RovieChannel.defaultPortalURL)/key/balance") else { return }
        components.queryItems = [URLQueryItem(name: "currency", value: currency)]
        guard let url = components.url else { return }

        isLoading = true
        lastError = nil

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                self.isLoading = false
                if self.currentBalance == nil { self.currentBalance = .zero(currency: currency) }
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                let decoder = JSONDecoder()
                let balance = try decoder.decode(RovieWalletBalance.self, from: data)
                self.currentBalance = balance
            } else {
                self.lastError = "HTTP \(httpResponse.statusCode)"
                self.currentBalance = .zero(currency: currency)
            }
            self.isLoading = false
        } catch {
            self.isLoading = false
            self.lastError = error.localizedDescription
            if self.currentBalance == nil {
                self.currentBalance = .zero(currency: currency)
            }
        }
    }
}
