import SwiftUI

ontinu  //
//  RovieTopUpSheet.swift
//  Rovie Mobile - chat page (AIChatView)
//
//  [RovieAccess] Bottom drawer raised when a turn fails on an empty Rovie
//  wallet or a saturated free model. Shows the live balance, sends the user to
//  the Route dashboard to top up, and picks the turn back up when they return.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

// MARK: - Host modifier

/// Presents `RovieTopUpSheet` whenever the view model raises a
/// `RovieAccessIssue`. Kept out of AIChatView.body so its type-checker stays
/// cheap.
struct RovieTopUpSheetModifier: ViewModifier {
    @ObservedObject var vm: AIChatViewModel
    /// Opens the model picker once the drawer has finished dismissing.
    let onChooseModel: () -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $vm.rovieAccessIssue) { issue in
            RovieTopUpSheet(
                issue: issue,
                onRetry: { vm.retry() },
                onChooseModel: onChooseModel
            )
        }
    }
}

// MARK: - Drawer

struct RovieTopUpSheet: View {
    let issue: RovieAccessIssue
    let onRetry: () -> Void
    let onChooseModel: () -> Void

    @ObservedObject private var wallet = RovieWalletClient.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Balance (USD) when the drawer opened; a top-up is any rise above it.
    @State private var baselineUsd: Double?
    /// The balance shown was fetched after this drawer opened, not left over
    /// from an earlier screen.
    @State private var hasFreshBalance = false
    /// The user went to the dashboard; refresh when the app comes back.
    @State private var leftForTopUp = false

    // MARK: State

    private var availableUsd: Double? { wallet.currentBalance?.availableUsd }

    /// Paid models are usable again.
    private var isFunded: Bool {
        guard hasFreshBalance, let now = availableUsd else { return false }
        switch issue {
        case .insufficientBalance:
            guard let baselineUsd else { return false }
            return now > baselineUsd
        case .freeModelLimited, .freeModelUnavailable:
            return now > 0
        }
    }

    private var title: String {
        switch (issue, isFunded) {
        case (.insufficientBalance, false): return AppLocalized("Balance too low")
        case (.insufficientBalance, true): return AppLocalized("Wallet topped up")
        case (.freeModelLimited, _): return AppLocalized("Free limit reached")
        case (.freeModelUnavailable, _): return AppLocalized("Free model unavailable")
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .padding(.top, 32)

            balance
                .padding(.top, 10)
                .padding(.bottom, 28)

            actions
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(285)])
        .presentationDragIndicator(.visible)
        .animation(.easeInOut(duration: 0.25), value: isFunded)
        .animation(.easeInOut(duration: 0.25), value: hasFreshBalance)
        .task { await refreshBalance() }
        .onChange(of: isFunded) { funded in
            if funded {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, leftForTopUp else { return }
            Task { await refreshBalance() }
        }
    }

    private var balance: some View {
        Text(hasFreshBalance ? (wallet.currentBalance?.formattedLocalAvailable ?? "—") : "₦0,000")
            .font(.system(size: 48, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(
                hasFreshBalance && wallet.currentBalance == nil ? .secondary : .primary
            )
            .contentTransition(.opacity)
            .redacted(reason: hasFreshBalance ? [] : .placeholder)
            .opacity(leftForTopUp && wallet.isLoading ? 0.4 : 1)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 6) {
            primaryButton
            secondaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if isFunded {
            switch issue {
            case .insufficientBalance:
                drawerButton(AppLocalized("Continue")) { finish(then: onRetry) }
            case .freeModelLimited, .freeModelUnavailable:
                drawerButton(AppLocalized("Choose a model")) { finish(then: onChooseModel) }
            }
        } else {
            drawerButton(AppLocalized("Top up"), systemImage: "arrow.up.right", action: openTopUp)
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        switch issue {
        case .insufficientBalance:
            secondary(AppLocalized("Not now")) { dismiss() }
        case .freeModelLimited, .freeModelUnavailable:
            secondary(AppLocalized("Try again")) { finish(then: onRetry) }
        }
    }

    // MARK: Pieces

    private func drawerButton(
        _ label: String, systemImage: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .imageScale(.small)
                }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .controlSize(.large)
    }

    private func secondary(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func openTopUp() {
        guard let url = RovieChannel.topUpURL else { return }
        if baselineUsd == nil { baselineUsd = availableUsd ?? 0 }
        leftForTopUp = true
        openURL(url)
    }

    private func finish(then next: @escaping () -> Void) {
        dismiss()
        next()
    }

    private func refreshBalance() async {
        guard let key = RovieChannel.storedAPIKey() else {
            hasFreshBalance = true
            return
        }
        await wallet.refreshBalance(apiKey: key)
        if baselineUsd == nil, wallet.lastError == nil {
            baselineUsd = availableUsd
        }
        hasFreshBalance = true
    }
}
