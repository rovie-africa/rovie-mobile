import Foundation

/// [RovieAccess] A Rovie Route failure the user can fix themselves — by
/// topping up, or by moving off a saturated free model — as opposed to a bug
/// or their own connection dropping.
///
/// Classification is deterministic and happens at the HTTP layer
/// (`RovieChannel.accessIssue(statusCode:body:modelId:)`), where the status
/// code and the gateway's error envelope are still available. The chat turn
/// later asks `RovieAccessMonitor` whether any request it made hit one of
/// these, so the answer survives group fallback re-wrapping the error.
enum RovieAccessIssue: String, Identifiable, Equatable, Sendable {
    /// HTTP 402, or the gateway's `insufficient_quota` / `budget_exceeded`
    /// envelope on a paid model.
    case insufficientBalance
    /// HTTP 429 on a free model.
    case freeModelLimited
    /// The free model's upstream answered 5xx, or the stream was dropped.
    case freeModelUnavailable

    var id: String { rawValue }

    var isFreeModel: Bool { self != .insufficientBalance }

    /// Higher wins when one turn hit several (a paid 402 that fell back to a
    /// rate-limited free model is still a balance problem at heart).
    fileprivate var priority: Int {
        switch self {
        case .insufficientBalance: return 3
        case .freeModelLimited: return 2
        case .freeModelUnavailable: return 1
        }
    }

    /// Short line shown in the failed assistant bubble.
    var inlineMessage: String {
        switch self {
        case .insufficientBalance: return AppLocalized("Your Rovie balance is too low.")
        case .freeModelLimited: return AppLocalized("Free model limit reached.")
        case .freeModelUnavailable: return AppLocalized("Free model unavailable right now.")
        }
    }
}

/// The error a chat turn rethrows once it has been classified as a
/// `RovieAccessIssue`. Keeps the original for logs; shows the clean line.
struct RovieAccessError: LocalizedError {
    let issue: RovieAccessIssue
    let underlying: Error

    var errorDescription: String? { issue.inlineMessage }
}

/// Thread-safe record of the most recent Rovie access issues, written by the
/// provider HTTP layer and read by the chat turn that owns the failure.
final class RovieAccessMonitor: @unchecked Sendable {
    static let shared = RovieAccessMonitor()

    private let lock = NSLock()
    private var lastSeen: [RovieAccessIssue: Date] = [:]

    private init() {}

    func record(_ issue: RovieAccessIssue, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastSeen[issue] = date
    }

    /// The strongest issue recorded at or after `start`, or nil.
    func strongestIssue(since start: Date) -> RovieAccessIssue? {
        lock.lock(); defer { lock.unlock() }
        return lastSeen
            .filter { $0.value >= start }
            .map(\.key)
            .max { $0.priority < $1.priority }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        lastSeen.removeAll()
    }
}

extension RovieChannel {

    /// Where the user tops up their wallet.
    static var topUpURL: URL? { URL(string: "\(defaultPortalURL)/dashboard/billing") }

    /// Error codes the gateway (and the LiteLLM proxy behind it) uses for an
    /// empty wallet or an exhausted key budget.
    private static let balanceErrorCodes: Set<String> = [
        "insufficient_quota",
        "insufficient_balance",
        "insufficient_funds",
        "budget_exceeded",
        "payment_required"
    ]

    /// Classify a non-2xx gateway response. Pure.
    ///
    /// A free model never reports a balance problem from its body alone: an
    /// upstream's own `insufficient_quota` can be passed through on a free
    /// route, and telling a free-tier user to top up for that would be wrong.
    static func accessIssue(statusCode: Int, body: String, modelId: String) -> RovieAccessIssue? {
        if statusCode == 402 { return .insufficientBalance }
        let isFree = isFreeModel(modelId)
        if !isFree, bodyIndicatesInsufficientBalance(body) { return .insufficientBalance }
        guard isFree else { return nil }
        if statusCode == 429 { return .freeModelLimited }
        if (500...599).contains(statusCode) { return .freeModelUnavailable }
        return nil
    }

    static func bodyIndicatesInsufficientBalance(_ body: String) -> Bool {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let fields = [error["code"], error["type"]].compactMap { $0 as? String }.map { $0.lowercased() }
            if fields.contains(where: balanceErrorCodes.contains) { return true }
        }
        let lower = body.lowercased()
        return lower.contains("insufficient balance")
            || lower.contains("budget has been exceeded")
            || lower.contains("exceeded budget")
    }

    /// The stored Rovie Route API key, if the user is signed in.
    @MainActor
    static func storedAPIKey() -> String? {
        guard let instance = ProviderConfigStore.shared.instances.first(where: { $0.isRovieChannel }),
              let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id),
              !key.isEmpty else { return nil }
        return key
    }
}

