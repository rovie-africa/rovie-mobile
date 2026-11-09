import SwiftUI

//  RovieTopUpSheet.swift
//  Rovie Mobile - chat page (AIChatView)
//
//  [RovieAccess] Bottom drawer raised when a turn fails on an empty Rovie
//  wallet or a saturated free model. Communicates the status, shows the real
//  balance, markets Route micro-credits and leading models without slop or pills,
//  and resumes the conversation when funded.
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

    /// Selected plan amount
    @State private var selectedAmount: Int = 1_000
    /// Balance (USD) when the drawer opened; a top-up is any rise above it.
    @State private var baselineUsd: Double?
    /// Whether fresh balance has arrived since the drawer opened.
    @State private var hasFreshBalance = false
    /// The user went to the dashboard; refresh when the app comes back.
    @State private var leftForTopUp = false

    // MARK: Currency & Presets

    private var activeCurrency: String {
        wallet.currentBalance?.localCurrency ?? RovieWalletBalance.defaultCurrencyCode
    }

    private var presets: [RovieTopUpPreset] {
        RovieTopUpPreset.presets(for: activeCurrency)
    }

    private var selectedPreset: RovieTopUpPreset? {
        presets.first(where: { $0.amount == selectedAmount }) ?? presets.first
    }

    private var availableUsd: Double? { wallet.currentBalance?.availableUsd }

    /// Whether the user already has credit available to spend.
    private var hasAvailableFunds: Bool {
        guard let local = wallet.currentBalance?.availableLocal,
              let usd = wallet.currentBalance?.availableUsd else { return false }
        return local > 0.01 || usd > 0.005
    }

    /// Paid models are usable.
    private var isFunded: Bool {
        guard hasFreshBalance else { return false }
        if hasAvailableFunds { return true }
        if let baselineUsd, let now = availableUsd, now > baselineUsd {
            return true
        }
        return false
    }

    private var title: String {
        switch issue {
        case .freeModelLimited:
            return hasAvailableFunds ? AppLocalized("Continue with Route Balance") : AppLocalized("Daily Limit Reached")
        case .freeModelUnavailable:
            return AppLocalized("Model Busy")
        case .insufficientBalance:
            return hasAvailableFunds ? AppLocalized("Ready to Continue") : AppLocalized("Wallet Empty")
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .padding(.top, 28)

            balanceHero
                .padding(.top, 8)
                .padding(.bottom, 20)

            if !hasAvailableFunds {
                planSection
                    .padding(.bottom, 16)

                featureHighlight
                    .padding(.bottom, 22)
            } else {
                featureHighlight
                    .padding(.bottom, 24)
            }

            actions
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(hasAvailableFunds ? 320 : 450)])
        .presentationDragIndicator(.visible)
        .animation(.easeInOut(duration: 0.25), value: hasAvailableFunds)
        .animation(.easeInOut(duration: 0.25), value: selectedAmount)
        .task {
            syncDefaultPreset()
            await refreshBalance()
        }
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

    // MARK: Views

    private var balanceHero: some View {
        Group {
            if hasAvailableFunds {
                Text(wallet.currentBalance?.formattedLocalAvailable ?? "₦0")
                    .foregroundStyle(.primary)
            } else {
                switch issue {
                case .insufficientBalance:
                    Text(wallet.currentBalance?.formattedLocalAvailable ?? "₦0")
                        .foregroundStyle(.secondary)
                case .freeModelLimited:
                    Text(AppLocalized("0 Free Prompts"))
                        .font(.title.weight(.bold))
                        .foregroundStyle(.secondary)
                case .freeModelUnavailable:
                    Text(AppLocalized("Community Busy"))
                        .font(.title.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 42, weight: .bold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .contentTransition(.opacity)
        .opacity(wallet.isLoading && !hasFreshBalance ? 0.4 : 1)
    }

    private var planSection: some View {
        HStack(spacing: 8) {
            ForEach(presets) { preset in
                Button {
                    selectedAmount = preset.amount
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(preset.formatted)
                        .font(.system(size: 15, weight: selectedAmount == preset.amount ? .bold : .medium))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(selectedAmount == preset.amount ? Color.primary : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedAmount == preset.amount ? Color(uiColor: .secondarySystemBackground) : Color(uiColor: .tertiarySystemBackground).opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selectedAmount == preset.amount ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var featureHighlight: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Claude 3.7 · GPT-4o · DeepSeek")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                Text("Zero limits")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.6))
        )
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 6) {
            primaryButton
            secondaryButtons
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if hasAvailableFunds {
            drawerButton(AppLocalized("Continue")) { finish(then: onRetry) }
        } else {
            let label = "\(AppLocalized("Top up")) \(selectedPreset?.formatted ?? "")"
            drawerButton(label, systemImage: "arrow.up.right", action: openTopUp)
        }
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        if hasAvailableFunds {
            secondary(AppLocalized("Dismiss")) { dismiss() }
        } else {
            switch issue {
            case .insufficientBalance:
                secondary(AppLocalized("Custom amount on Route")) { openTopUpCustom() }
                secondary(AppLocalized("Switch to free model")) { finish(then: onChooseModel) }
                secondary(AppLocalized("Not now")) { dismiss() }
            case .freeModelLimited, .freeModelUnavailable:
                secondary(AppLocalized("Choose another model")) { finish(then: onChooseModel) }
                secondary(AppLocalized("Not now")) { dismiss() }
            }
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
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func openTopUp() {
        guard let url = RovieChannel.topUpURL(amount: selectedAmount, currency: activeCurrency) else { return }
        if baselineUsd == nil { baselineUsd = availableUsd ?? 0 }
        leftForTopUp = true
        openURL(url)
    }

    private func openTopUpCustom() {
        guard let url = RovieChannel.topUpURL(amount: nil, currency: activeCurrency) else { return }
        if baselineUsd == nil { baselineUsd = availableUsd ?? 0 }
        leftForTopUp = true
        openURL(url)
    }

    private func finish(then next: @escaping () -> Void) {
        dismiss()
        next()
    }

    private func syncDefaultPreset() {
        if let defaultOption = presets.dropFirst().first ?? presets.first {
            selectedAmount = defaultOption.amount
        }
    }

    private func refreshBalance() async {
        await wallet.refreshBalance()
        if baselineUsd == nil, wallet.lastError == nil {
            baselineUsd = availableUsd
        }
        hasFreshBalance = true
    }
}
