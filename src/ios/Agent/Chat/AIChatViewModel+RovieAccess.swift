import Foundation

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Rovie Route access failures [RovieAccess]

extension AIChatViewModel {

    /// Decide whether a failed turn was a Rovie wallet / free-tier problem.
    /// If so, raise the top-up drawer and return a `RovieAccessError` whose
    /// description is the clean inline line; otherwise return `error` as-is.
    ///
    /// Called once, from `runAgentLoop`, which every send / retry / resume /
    /// queued-drain path funnels through.
    func classifyRovieAccessFailure(_ error: Error, since start: Date) -> Error {
        if error is CancellationError || turnWasStopped { return error }
        if case .cancelled? = error as? LLMError { return error }
        if error is RovieAccessError { return error }

        guard let issue = RovieAccessMonitor.shared.strongestIssue(since: start)
                ?? droppedFreeModelIssue(for: error) else { return error }

        RovieAccessMonitor.shared.clear()
        logger.info("[RovieAccess] turn failed with \(issue.rawValue); raw=\(String(describing: error).prefix(300))")
        rovieAccessIssue = issue
        return RovieAccessError(issue: issue, underlying: error)
    }

    /// A free Rovie model whose stream stalled, came back empty, or had its
    /// connection cut by the gateway. None of these carry an HTTP status, so
    /// the provider layer cannot classify them.
    private func droppedFreeModelIssue(for error: Error) -> RovieAccessIssue? {
        guard let entry = resolveCurrentEntry(),
              ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.isRovieChannel == true,
              RovieChannel.isFreeModel(entry.model.id),
              let llm = error as? LLMError else { return nil }
        switch llm {
        case .transientError(_, nil):
            return .freeModelUnavailable
        case .networkError(let underlying):
            let ns = underlying as NSError
            return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNetworkConnectionLost
                ? .freeModelUnavailable : nil
        default:
            return nil
        }
    }
}

