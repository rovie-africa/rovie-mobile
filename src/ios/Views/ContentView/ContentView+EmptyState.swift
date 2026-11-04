//
//  ContentView+EmptyState.swift
//  Rovie Mobile - home screen empty state (welcome & auth entry)
//

import SwiftUI
import SafariServices

extension ContentView {
    // MARK: - Empty State

    /// [T-onboarding-hide-fab] Whether the floating New Chat / Search buttons
    /// stay hidden during initial onboarding.
    func hidesFABForOnboarding(listIsEmpty: Bool) -> Bool {
        listIsEmpty && !showSearchBar && providerStore.modelGroups.isEmpty
    }

    var emptyState: some View {
        let hasRovieInstance = providerStore.instances.contains(where: { RovieChannel.looksLikeRovieBaseURL($0.customBaseURL) })
        let rovieKey: String? = {
            guard let inst = providerStore.instances.first(where: { RovieChannel.looksLikeRovieBaseURL($0.customBaseURL) }) else { return nil }
            return ProviderKeychainHelper.loadAPIKey(instanceId: inst.id)
        }()
        let isConfigured = hasRovieInstance && rovieKey != nil && !(rovieKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && !providerStore.modelGroups.isEmpty

        return VStack(spacing: 32) {
            Spacer()

            // App icon / hero
            Image("RovieLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
                .padding(.bottom, 4)

            VStack(spacing: 8) {
                Text("Welcome to Rovie")
                    .font(.title2.bold())
                Text(isConfigured ? "Ready to assist. Start a conversation to begin." : "Set up your new device personal assistant")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)

            Spacer()

            if isConfigured {
                VStack(spacing: 12) {
                    Button {
                        NotificationCenter.default.post(name: .newChatRequested, object: nil)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.bubble.fill")
                                .font(.body.weight(.semibold))
                            Text("Start New Chat")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 24)
            } else {
                // Login / Auth Action
                VStack(spacing: 12) {
                    Button {
                        RovieAuthSession.shared.startLogin { result in
                            switch result {
                            case .success(let key):
                                RovieChannel.configureWithApiKey(key)
                            case .failure(let error):
                                print("[RovieAuth] Login failed or cancelled: \(error.localizedDescription)")
                                if let url = URL(string: "\(RovieChannel.defaultPortalURL)/signin?next=/auth/mobile") {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right.square.fill")
                                .font(.body.weight(.semibold))
                            Text("Log in with Rovie")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        showAddProvider = true
                    } label: {
                        Text("Enter API key")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 32)
        .sheet(isPresented: $showAddProvider) {
            EnterRovieKeySheet()
        }
        .sheet(isPresented: $showSelectModels) {
            NavigationStack {
                OnboardingModelSelectionView()
            }
        }
    }
}

private struct EnterRovieKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-rovie-...", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Rovie Route API Key")
                }
            }
            .navigationTitle("API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        RovieChannel.configureWithApiKey(apiKey)
                        dismiss()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.fraction(0.35)])
    }
}
