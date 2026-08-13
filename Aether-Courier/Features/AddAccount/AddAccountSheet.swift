import SwiftUI
import EmailKit

/// The add-account flow. Password/app-password/bridge providers take a secret
/// inline; Gmail/Outlook run the OAuth browser flow. On success the account is
/// persisted (Keychain + accounts.json) so it stays across relaunches.
struct AddAccountSheet: View {
    @Environment(CourierStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var provider: MailProvider = .icloud
    @State private var email = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var customIMAPHost = ""
    @State private var customSMTPHost = ""
    @State private var busy = false
    @State private var error: String?
    @State private var testResult: TestResult?
    @State private var oauth = OAuthLoginController()

    private enum TestResult: Equatable { case ok, fail(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Mail Account").font(.title2).fontWeight(.semibold)

            Picker("Service", selection: $provider) {
                ForEach(MailProvider.allCases) { p in Text(p.displayName).tag(p) }
            }
            .pickerStyle(.segmented)

            Text(ProviderCatalog.setupHint(for: provider))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Email address", text: $email)
                    .textContentType(.username)
                TextField("Display name (optional)", text: $displayName)

                switch provider.authKind {
                case .oauth:
                    if oauthClientID.isEmpty {
                        Label("Add a \(provider.displayName) client ID in Settings → Providers first.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                case .appPassword, .password, .bridge:
                    SecureField(provider == .icloud ? "App-specific password" : "Password", text: $password)
                    if provider == .custom || provider == .proton {
                        TextField("IMAP host", text: $customIMAPHost)
                        TextField("SMTP host", text: $customSMTPHost)
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            switch testResult {
            case .ok:
                Label("Connected — credentials accepted.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout)
            case .fail(let msg):
                Label(msg, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if provider.authKind != .oauth {
                    Button("Test") { Task { await test() } }
                        .disabled(!canSubmit || busy)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(primaryLabel) { Task { await add() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit || busy)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear(perform: prefillCustomHosts)
        .onChange(of: provider) { _, _ in prefillCustomHosts() }
    }

    // MARK: derived

    private var oauthClientID: String {
        provider == .gmail ? store.settings.googleClientID
            : provider == .outlook ? store.settings.microsoftClientID : ""
    }

    private var primaryLabel: String {
        provider.authKind == .oauth ? "Sign In…" : "Add Account"
    }

    private var canSubmit: Bool {
        guard email.contains("@") else { return false }
        switch provider.authKind {
        case .oauth: return !oauthClientID.isEmpty
        case .appPassword, .password, .bridge: return !password.isEmpty
        }
    }

    private func prefillCustomHosts() {
        customIMAPHost = ProviderCatalog.imap(for: provider).host
        customSMTPHost = ProviderCatalog.smtp(for: provider).host
    }

    // MARK: actions

    private func test() async {
        busy = true; error = nil; testResult = nil
        defer { busy = false }
        var imap = ProviderCatalog.imap(for: provider)
        if provider == .custom || provider == .proton { imap.host = customIMAPHost }
        if let err = await store.testConnection(provider: provider, email: email, password: password, imap: imap) {
            testResult = .fail(err)
        } else {
            testResult = .ok
        }
    }

    private func add() async {
        busy = true; error = nil
        defer { busy = false }
        switch provider.authKind {
        case .oauth:
            let secret = provider == .gmail ? Keychain.getString(account: "google-client-secret") : nil
            guard let config = ProviderCatalog.oauth(for: provider, clientID: oauthClientID, clientSecret: secret, tenant: store.settings.microsoftTenant) else {
                error = "OAuth is not configured."; return
            }
            do {
                let tokens = try await oauth.signIn(config: config)
                await store.addOAuthAccount(provider: provider, email: email, displayName: displayName, tokens: tokens)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        case .appPassword, .password, .bridge:
            var imap = ProviderCatalog.imap(for: provider)
            var smtp = ProviderCatalog.smtp(for: provider)
            if provider == .custom || provider == .proton {
                imap.host = customIMAPHost
                smtp.host = customSMTPHost
            }
            await store.addPasswordAccount(provider: provider, email: email, displayName: displayName,
                                           password: password, imap: imap, smtp: smtp)
            dismiss()
        }
    }
}
