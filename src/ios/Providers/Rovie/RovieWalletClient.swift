import Foundation
import Combine

/// [RovieWalletBalance] Decoded wallet budget state from Rovie Route
public struct RovieWalletBalance: Codable, Sendable {
    public let availableUsd: Double
    public let spendUsd: Double
    public let maxBudgetUsd: Double?
    public let localCurrency: String
    public let availableLocal: Double
    public let spendLocal: Double
    public let maxBudgetLocal: Double?
    public let country: String

    public var formattedLocalAvailable: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = localCurrency
        formatter.maximumFractionDigits = 0
        
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
        default:
            formatter.currencySymbol = localCurrency + " "
        }
        
        return formatter.string(from: NSNumber(value: availableLocal)) ?? "\(localCurrency) \(Int(availableLocal))"
    }
}

/// Observable client for monitoring Rovie Route wallet balance
@MainActor
public final class RovieWalletClient: ObservableObject {
    public static let shared = RovieWalletClient()

    @Published public private(set) var currentBalance: RovieWalletBalance?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastError: String?

    private init() {}

    /// Refresh balance from the portal using the user's Rovie Route API key
    public func refreshBalance(apiKey: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.currentBalance = nil
            return
        }

        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(RovieChannel.defaultPortalURL)/key/balance") else { return }

        isLoading = true
        lastError = nil

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                self.isLoading = false
                self.lastError = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .useDefaultKeys
            let balance = try decoder.decode(RovieWalletBalance.self, from: data)
            self.currentBalance = balance
            self.isLoading = false
        } catch {
            self.isLoading = false
            self.lastError = error.localizedDescription
        }
    }
}
