import SwiftUI
import SafariServices

/// [RovieBalancePill] Navigation bar pill displaying the user's active local currency wallet balance.
/// Tap opens route.rovie.africa in Safari for instant top-ups.
public struct RovieBalancePill: View {
    @ObservedObject var wallet = RovieWalletClient.shared
    @State private var showSafari = false

    public init() {}

    public var body: some View {
        Button {
            showSafari = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)

                if let balance = wallet.currentBalance {
                    Text(balance.formattedLocalAvailable)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                } else if wallet.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Text("₦ Top-up")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(UIColor.secondarySystemFill))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSafari) {
            if let url = URL(string: RovieChannel.defaultPortalURL) {
                RovieSafariView(url: url)
            }
        }
    }
}

/// Simple SafariServices sheet wrapper for top-up portal
struct RovieSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - SwiftUI Preview for On-Device Canvas (Option 2)

#Preview("Rovie Balance Pill - Live", traits: .sizeThatFitsLayout) {
    HStack {
        RovieBalancePill()
    }
    .padding()
}

