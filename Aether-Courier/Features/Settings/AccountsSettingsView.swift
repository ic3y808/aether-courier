import SwiftUI
import EmailKit

/// Manage configured accounts: update a password/display name (the fix-my-login
/// path) or remove an account entirely.
struct AccountsSettingsView: View {
    @Environment(CourierStore.self) private var store

    var body: some View {
        Form {
            if store.accounts.isEmpty {
                ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.plus",
                                       description: Text("Add one from the sidebar’s “Add Account” button."))
            }
            ForEach(store.accounts) { account in
                Section {
                    AccountRow(account: account)
                } header: {
                    HStack {
                        Text(account.emailAddress)
                        Spacer()
                        Text(account.provider.displayName).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountRow: View {
    @Environment(CourierStore.self) private var store
    let account: MailAccount

    @State private var displayName: String = ""
    @State private var newPassword: String = ""
    @State private var busy = false
    @State private var status: String?
    @State private var confirmRemove = false
    @State private var syncAll: Bool = true
    @State private var syncCount: Int = 200

    var body: some View {
        Group {
            TextField("Display name", text: $displayName)

            if account.provider.authKind == .oauth {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OAuth Sign-in").font(.callout).bold()
                        Text("Re-authenticate to renew access tokens").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Re-authenticate Now") {
                        store.reauthenticateAccount(account)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                SecureField(account.provider == .icloud ? "New app-specific password" : "New password",
                            text: $newPassword)
                HStack {
                    Button("Test") { Task { await test() } }
                        .disabled(busy || newPassword.isEmpty)
                    Button("Save & Reconnect") { Task { await save() } }
                        .disabled(busy || (newPassword.isEmpty && displayName == account.displayName))
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }

            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Sync history depth.
            Toggle("Sync all history (recommended)", isOn: $syncAll)
            if !syncAll {
                Stepper("Last \(syncCount) messages per folder", value: $syncCount, in: 50...10000, step: 50)
            }
            Button("Apply Sync Setting") {
                Task { await store.setSyncLimit(account, syncAll ? nil : syncCount) }
            }
            .disabled(busy)

            Button("Remove Account", role: .destructive) { confirmRemove = true }
                .confirmationDialog("Remove \(account.emailAddress)?", isPresented: $confirmRemove) {
                    Button("Remove", role: .destructive) { store.removeAccount(account) }
                } message: {
                    Text("This deletes the account from Aether Courier and its stored credential. Your mail on the server is untouched.")
                }
        }
        .onAppear {
            displayName = account.displayName
            if let n = account.syncLimit, n > 0 { syncAll = false; syncCount = n } else { syncAll = true }
        }
    }

    private func test() async {
        busy = true; status = nil
        defer { busy = false }
        if let err = await store.testConnection(provider: account.provider, email: account.emailAddress,
                                                password: newPassword, imap: account.imap) {
            status = "✗ \(err)"
        } else {
            status = "✓ Connected — credentials accepted."
        }
    }

    private func save() async {
        busy = true; status = nil
        defer { busy = false }
        await store.updateAccount(account,
                                  newPassword: newPassword.isEmpty ? nil : newPassword,
                                  newDisplayName: displayName)
        newPassword = ""
        status = store.banner == nil ? "✓ Saved and reconnected." : "✗ \(store.banner ?? "")"
    }
}
