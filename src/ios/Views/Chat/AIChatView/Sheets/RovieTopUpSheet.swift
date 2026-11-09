import SwiftUI

//  RovieTopUpSheet.swift
//  Rovie Mobile - chat page (AIChatView)
//
//  [RovieAccess] Bottom drawer raised when a turn fails on an empty Rovie
//  wallet or a saturated free model. Uses a continuous 120Hz magnetic slider
//  and fluid spring animations without pills, tags, or explainers.
//

// MARK: - Host modifier

struct RovieTopUpSheetModifier: ViewModifier {
    @ObservedObject var vm: AIChatViewModel
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

    @State private var stepIndex: Int = 2
    @State private var isDraggingSlider = false
    @State private var appeared = false
    @State private var baselineUsd: Double?
    @State private var hasFreshBalance = false
    @State private var leftForTopUp = false

    // MARK: Currency & Steps

    private var activeCurrency: String {
        wallet.currentBalance?.localCurrency ?? RovieWalletBalance.defaultCurrencyCode
    }

    private var steps: [RovieTopUpPreset] {
        RovieTopUpPreset.steps(for: activeCurrency)
    }

    private var clampedIndex: Int {
        guard !steps.isEmpty else { return 0 }
        return min(max(stepIndex, 0), steps.count - 1)
    }

    private var selectedPreset: RovieTopUpPreset? {
        guard !steps.isEmpty else { return nil }
        return steps[clampedIndex]
    }

    private var selectedAmount: Int {
        selectedPreset?.amount ?? 1_000
    }

    private var availableUsd: Double? { wallet.currentBalance?.availableUsd }

    private var hasAvailableFunds: Bool {
        guard let local = wallet.currentBalance?.availableLocal,
              let usd = wallet.currentBalance?.availableUsd else { return false }
        return local > 0.01 || usd > 0.005
    }

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
            return hasAvailableFunds ? AppLocalized("Continue with Route") : AppLocalized("Daily Limit Reached")
        case .freeModelUnavailable:
            return AppLocalized("Model Busy")
        case .insufficientBalance:
            return hasAvailableFunds ? AppLocalized("Ready to Continue") : AppLocalized("Wallet Empty")
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.top, 26)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

            Spacer(minLength: 14)

            heroAmount
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.94)

            if !hasAvailableFunds {
                RovieAmountSlider(
                    steps: steps,
                    selectedIndex: $stepIndex,
                    isDragging: $isDraggingSlider,
                    onCustomAmount: openTopUpCustom
                )
                .padding(.top, 18)
                .padding(.bottom, 22)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
            } else {
                Spacer(minLength: 24)
            }

            actions
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(hasAvailableFunds ? 260 : 365)])
        .presentationDragIndicator(.visible)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: hasAvailableFunds)
        .animation(.spring(response: 0.24, dampingFraction: 0.74), value: stepIndex)
        .animation(.spring(response: 0.26, dampingFraction: 0.68), value: isDraggingSlider)
        .onAppear {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .task {
            syncDefaultStep()
            await refreshBalance()
        }
        .onChange(of: activeCurrency) { _ in
            syncDefaultStep()
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

    // MARK: Header & Hero

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            Spacer()

            if !hasAvailableFunds {
                Text(wallet.currentBalance?.formattedLocalAvailable ?? "₦0.00")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(wallet.isLoading && !hasFreshBalance ? 0.35 : 1)
            }
        }
    }

    private var heroAmount: some View {
        let displayString = hasAvailableFunds
            ? (wallet.currentBalance?.formattedLocalAvailable ?? "₦0.00")
            : (selectedPreset?.formatted ?? "₦1,000")

        return RovieRollingAmountText(
            text: displayString,
            numericValue: Double(selectedAmount)
        )
        .font(.system(size: 54, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .scaleEffect(isDraggingSlider ? 1.07 : 1.0)
        .offset(y: isDraggingSlider ? -2 : 0)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Actions

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
            drawerButton(AppLocalized("Continue"), action: { finish(then: onRetry) })
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
                secondary(AppLocalized("Switch to free model")) { finish(then: onChooseModel) }
            case .freeModelLimited, .freeModelUnavailable:
                secondary(AppLocalized("Choose another model")) { finish(then: onChooseModel) }
            }
        }
    }

    private func drawerButton(
        _ label: String, systemImage: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RovieRollingAmountText(text: label, numericValue: Double(selectedAmount))
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .imageScale(.small)
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor)
            )
        }
        .buttonStyle(RoviePressButtonStyle())
    }

    private func secondary(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: Logic

    private func openTopUp() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard let url = RovieChannel.topUpURL(amount: selectedAmount, currency: activeCurrency) else { return }
        if baselineUsd == nil { baselineUsd = availableUsd ?? 0 }
        leftForTopUp = true
        openURL(url)
    }

    private func openTopUpCustom() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let url = RovieChannel.topUpURL(amount: nil, currency: activeCurrency) else { return }
        if baselineUsd == nil { baselineUsd = availableUsd ?? 0 }
        leftForTopUp = true
        openURL(url)
    }

    private func finish(then next: @escaping () -> Void) {
        dismiss()
        next()
    }

    private func syncDefaultStep() {
        let count = steps.count
        guard count > 0 else { return }
        stepIndex = min(2, count - 1)
    }

    private func refreshBalance() async {
        await wallet.refreshBalance()
        if baselineUsd == nil, wallet.lastError == nil {
            baselineUsd = availableUsd
        }
        hasFreshBalance = true
    }
}

// MARK: - Continuous Magnetic Scrubber Slider

private struct RovieAmountSlider: View {
    let steps: [RovieTopUpPreset]
    @Binding var selectedIndex: Int
    @Binding var isDragging: Bool
    let onCustomAmount: () -> Void

    /// Live continuous progress (0...1) while finger is down so the thumb tracks
    /// at 120Hz with magnetic pull toward each step, then snaps cleanly on release.
    @State private var liveDragProgress: CGFloat?
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
    @State private var boundaryFeedback = UIImpactFeedbackGenerator(style: .rigid)

    private let thumbSize: CGFloat = 32

    private var stepCount: Int {
        max(steps.count - 1, 1)
    }

    private var discreteProgress: CGFloat {
        guard steps.count > 1 else { return 0 }
        let clamped = min(max(selectedIndex, 0), steps.count - 1)
        return CGFloat(clamped) / CGFloat(stepCount)
    }

    /// Blends raw finger position with magnetic attraction toward the snapped step.
    private var effectiveProgress: CGFloat {
        guard let raw = liveDragProgress else { return discreteProgress }
        return raw * 0.72 + discreteProgress * 0.28
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let usableWidth = max(geo.size.width - thumbSize, 1)
                let thumbOffset = usableWidth * effectiveProgress
                let activeTrackHeight: CGFloat = isDragging ? 18 : 14

                ZStack(alignment: .leading) {
                    // Sculpted track background
                    Capsule(style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                        .frame(height: activeTrackHeight)

                    // Active gradient fill
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(thumbOffset + thumbSize * 0.5, activeTrackHeight), height: activeTrackHeight)

                    // Precision step ticks
                    HStack(spacing: 0) {
                        ForEach(steps.indices, id: \.self) { idx in
                            let stepRatio = CGFloat(idx) / CGFloat(stepCount)
                            let isPassed = stepRatio <= effectiveProgress + 0.005
                            let isCurrent = idx == selectedIndex
                            let isMajor = idx == 0 || idx == steps.count - 1 || idx % 3 == 0

                            Capsule(style: .continuous)
                                .fill(
                                    isPassed
                                        ? Color.white.opacity(isCurrent ? 0.9 : 0.45)
                                        : Color.primary.opacity(isMajor ? 0.22 : 0.12)
                                )
                                .frame(
                                    width: isMajor ? 3 : 2,
                                    height: isDragging ? (isMajor ? 8 : 5) : (isMajor ? 6 : 4)
                                )

                            if idx < steps.count - 1 {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, thumbSize * 0.5 - 1.5)

                    // Elevated dual-ring tactile thumb
                    ZStack {
                        Circle()
                            .fill(Color(uiColor: .systemBackground))
                            .frame(width: thumbSize, height: thumbSize)
                            .shadow(
                                color: Color.black.opacity(isDragging ? 0.24 : 0.14),
                                radius: isDragging ? 10 : 5,
                                y: isDragging ? 4 : 2
                            )

                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: isDragging ? 3.5 : 2.5)
                            .frame(width: thumbSize, height: thumbSize)

                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: isDragging ? 12 : 8, height: isDragging ? 12 : 8)
                    }
                    .scaleEffect(isDragging ? 1.14 : 1.0)
                    .offset(x: thumbOffset)
                }
                .frame(height: thumbSize)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
                                    isDragging = true
                                }
                                selectionFeedback.prepare()
                                boundaryFeedback.prepare()
                            }

                            let x = value.location.x - thumbSize * 0.5
                            let ratio = min(max(x / usableWidth, 0), 1)
                            liveDragProgress = ratio

                            let targetIndex = Int(round(ratio * CGFloat(stepCount)))
                            if targetIndex != selectedIndex {
                                selectedIndex = targetIndex
                                if targetIndex == 0 || targetIndex == steps.count - 1 {
                                    boundaryFeedback.impactOccurred(intensity: 0.8)
                                } else {
                                    selectionFeedback.selectionChanged()
                                }
                            }
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                liveDragProgress = nil
                                isDragging = false
                            }
                        }
                )
            }
            .frame(height: thumbSize)

            // Tappable bounds + Custom amount link in Rovie Route
            HStack(alignment: .center) {
                Button {
                    guard selectedIndex != 0 else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                        selectedIndex = 0
                    }
                    selectionFeedback.selectionChanged()
                } label: {
                    Text(steps.first?.formatted ?? "")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onCustomAmount) {
                    HStack(spacing: 3) {
                        Text(AppLocalized("Custom amount in Rovie Route"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    let last = max(steps.count - 1, 0)
                    guard selectedIndex != last else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                        selectedIndex = last
                    }
                    selectionFeedback.selectionChanged()
                } label: {
                    Text(steps.last?.formatted ?? "")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Rolling Amount & Button Style

private struct RovieRollingAmountText: View {
    let text: String
    let numericValue: Double

    var body: some View {
        if #available(iOS 17.0, *) {
            Text(text)
                .contentTransition(.numericText(value: numericValue))
        } else {
            Text(text)
                .contentTransition(.opacity)
        }
    }
}

private struct RoviePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
