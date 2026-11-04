//
//  ManageAccountView.swift
//  Rovie Mobile - Account Management
//

import SwiftUI
import SafariServices

struct ManageAccountView: View {
    @ObservedObject private var store = ProviderConfigStore.shared
    @ObservedObject private var wallet = RovieWalletClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showApiKeySheet = false
    @State private var newApiKeyInput = ""
    @State private var isTestingConnection = false
    @State private var connectionStatusMessage: String?
    @State private var showSignOutAlert = false
    @State private var refreshId = UUID()

    private var rovieInstance: ProviderInstance? {
        store.instances.first(where: { RovieChannel.looksLikeRovieBaseURL($0.customBaseURL) })
    }

    private var currentApiKey: String? {
        _ = refreshId
        guard let id = rovieInstance?.id else { return nil }
        return ProviderKeychainHelper.loadAPIKey(instanceId: id)
    }

    private var isConnected: Bool {
        guard let key = currentApiKey, !key.isEmpty else { return false }
        return rovieInstance?.isEnabled ?? false
    }

    private var maskedApiKey: String {
        guard let key = currentApiKey, !key.isEmpty else { return "None" }
        if key.count > 12 {
            let prefix = String(key.prefix(7))
            return "\(prefix)••••••••"
        }
        return "••••••••"
    }

    var body: some View {
        List {
            // Status Section
            Section("Account") {
                HStack(spacing: 12) {
                    Image("RovieLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rovie Route")
                            .font(.headline)
                        Text(isConnected ? "Connected" : "Not connected")
                            .font(.subheadline)
                            .foregroundStyle(isConnected ? .green : .secondary)
                    }

                    Spacer()

                    if wallet.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .padding(.vertical, 4)
            }

            // Wallet Section
            Section("Wallet") {
                HStack {
                    Text("Balance")
                    Spacer()
                    if let balance = wallet.currentBalance {
                        Text(balance.formattedLocalAvailable)
                            .font(.headline)
                    } else if isConnected {
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    if let url = URL(string: RovieChannel.defaultPortalURL) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Top Up Wallet", systemImage: "creditcard")
                }
            }

            // Authentication Section
            Section("Credentials") {
                HStack {
                    Text("API Key")
                    Spacer()
                    Text(maskedApiKey)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }

                Button {
                    RovieAuthSession.shared.startLogin { result in
                        switch result {
                        case .success(let key):
                            RovieChannel.configureWithApiKey(key)
                            refreshId = UUID()
                        case .failure(let error):
                            print("[ManageAccount] Login failed: \(error)")
                        }
                    }
                } label: {
                    Label("Log In with Rovie", systemImage: "arrow.up.right.square")
                }

                Button {
                    newApiKeyInput = ""
                    showApiKeySheet = true
                } label: {
                    Label("Update API Key", systemImage: "key")
                }
            }

            // Connection Diagnostics
            Section("Diagnostics") {
                Button {
                    testConnection()
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "network")
                        Spacer()
                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if let status = connectionStatusMessage {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(status == "Success" ? .green : .red)
                        }
                    }
                }
                .disabled(isTestingConnection || !isConnected)

                Button {
                    refreshModels()
                } label: {
                    Label("Refresh Models", systemImage: "arrow.clockwise")
                }
                .disabled(!isConnected)
            }

            // Sign Out
            if isConnected {
                Section {
                    Button(role: .destructive) {
                        showSignOutAlert = true
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .navigationTitle("Manage Account")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let key = currentApiKey {
                await wallet.refreshBalance(apiKey: key)
            }
        }
        .sheet(isPresented: $showApiKeySheet) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("sk-rovie-...", text: $newApiKeyInput)
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
                        Button("Cancel") { showApiKeySheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            RovieChannel.configureWithApiKey(newApiKeyInput)
                            refreshId = UUID()
                            showApiKeySheet = false
                        }
                        .disabled(newApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.fraction(0.35)])
        }
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                signOut()
            }
        } message: {
            Text("This will remove your stored Rovie key from this device.")
        }
        .onAppear {
            refreshId = UUID()
            if let key = currentApiKey {
                Task {
                    await wallet.refreshBalance(apiKey: key)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rovieAuthCompleted)) { _ in
            refreshId = UUID()
            if let key = currentApiKey {
                Task {
                    await wallet.refreshBalance(apiKey: key)
                }
            }
        }
    }

    private func testConnection() {
        guard let key = currentApiKey else { return }
        isTestingConnection = true
        connectionStatusMessage = nil

        Task {
            guard let url = URL(string: "\(RovieChannel.defaultBaseURL)/models") else {
                await MainActor.run {
                    isTestingConnection = false
                    connectionStatusMessage = "Failed"
                }
                return
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 8

            do {
                let (_, res) = try await URLSession.shared.data(for: req)
                let ok = (res as? HTTPURLResponse)?.statusCode == 200
                await MainActor.run {
                    isTestingConnection = false
                    connectionStatusMessage = ok ? "Success" : "Failed"
                }
            } catch {
                await MainActor.run {
                    isTestingConnection = false
                    connectionStatusMessage = "Failed"
                }
            }
        }
    }

    private func refreshModels() {
        guard let instance = rovieInstance else { return }
        Task {
            await store.refreshModels(for: instance)
            if let key = currentApiKey {
                await wallet.refreshBalance(apiKey: key)
            }
        }
    }

    private func signOut() {
        if let instance = rovieInstance {
            ProviderKeychainHelper.deleteAPIKey(instanceId: instance.id)
            store.removeInstance(instance.id)
            refreshId = UUID()
        }
    }
}
