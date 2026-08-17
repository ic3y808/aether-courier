import SwiftUI
import AppKit

/// App settings: the Aether backend (AI only), OAuth client IDs the user
/// registers with Google/Microsoft, and sync preferences.
struct SettingsView: View {
    @Environment(CourierStore.self) private var store
    @State private var draft = CourierSettings.load()
    @State private var backendToken = Keychain.getString(account: "aether-backend-token") ?? ""
    @State private var googleSecret = Keychain.getString(account: "google-client-secret") ?? ""
    @State private var newBlock = ""

    var body: some View {
        TabView {
            AccountsSettingsView().tabItem { Label("Accounts", systemImage: "person.2") }
            aiTab.tabItem { Label("AI / Backend", systemImage: "sparkles") }
            providersTab.tabItem { Label("Providers", systemImage: "key") }
            syncTab.tabItem { Label("Privacy & Sync", systemImage: "hand.raised") }
            blockedTab.tabItem { Label("Blocked", systemImage: "nosign") }
        }
        .padding(20)
        .onDisappear(perform: persist)
    }

    private var aiTab: some View {
        Form {
            Section("AI Source") {
                Picker("Copilot runs on", selection: $draft.aiUseLocal) {
                    Text("This Mac (Ollama / LM Studio) — fastest").tag(true)
                    Text("Aether hub (network)").tag(false)
                }
                .pickerStyle(.inline)
                if draft.aiUseLocal {
                    TextField("Local host", text: $draft.localAIHost)
                        .help("Ollama: 127.0.0.1:11434 · LM Studio: 127.0.0.1:1234")
                    Text("No token needed — requests never leave this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !draft.aiUseLocal {
                Section("Aether Hub") {
                    TextField("Backend host", text: $draft.backendHost)
                        .help("e.g. 10.0.0.15 or aether.example.com")
                    SecureField("Aether token", text: $backendToken)
                        .help("Shared Aether token; stored in the Keychain, sent as X-Aether-Token.")
                }
            }
            Section("Model") {
                HStack {
                    Picker("AI model", selection: $draft.aiModel) {
                        // Always include the current value so the picker shows it
                        // even before the server list loads.
                        if !store.availableModels.contains(draft.aiModel) {
                            Text(draft.aiModel).tag(draft.aiModel)
                        }
                        ForEach(store.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        store.applySettings(draft)   // apply host/token first
                        Task { await store.loadModels() }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help("Load models from the backend")
                }
                TextField("…or type a model id", text: $draft.aiModel)
                    .font(.caption)
            }
            Section("Copilot") {
                Picker("How much the AI does on its own", selection: $draft.aiAutonomy) {
                    ForEach(AIAutonomy.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(draft.aiAutonomy.blurb)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Try **Aggressive**, then ask the Copilot to “organize & triage everything” — it sorts mail into folders, archives low‑value updates, stars what's important, and clears spam.")
                    .font(.caption2).foregroundStyle(.secondary)

                Toggle("Reveal the Copilot for relevant emails", isOn: $draft.autoRevealCopilot)
                Text("Slides the Copilot in when an email looks like a receipt, newsletter, meeting or something suspicious — and out again when it's not. Toggling it yourself (⌘J) turns this off for the session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Mail servers are never contacted through the Aether backend — only AI requests are.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { if store.availableModels.isEmpty { await store.loadModels() } }
    }

    private var providersTab: some View {
        Form {
            Section("Google (Gmail)") {
                TextField("OAuth client ID", text: $draft.googleClientID)
                SecureField("Client secret (Desktop/Web clients)", text: $googleSecret)
                Text("Google Cloud Console → Credentials → OAuth client ID → Desktop app. Paste both the client ID and its secret. (iOS clients have no secret — leave it blank.)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microsoft (Outlook)") {
                TextField("Azure Entra Client ID", text: $draft.microsoftClientID)
                if draft.microsoftClientID.hasPrefix("GOCSPX-") {
                    Label("This is a Google Cloud Client Secret ('GOCSPX-...'). Replace it with your Azure Application (client) ID (GUID format) from portal.azure.com.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
                Picker("Azure Supported Account Type", selection: $draft.microsoftTenant) {
                    Text("Any Entra ID Tenant + Personal Microsoft accounts").tag("common")
                    Text("Personal accounts only").tag("consumers")
                    Text("Single tenant / Multiple Entra ID tenants").tag("organizations")
                }
                Text("In Azure Portal → App Registrations → Authentication → Add a platform → Mobile and desktop applications, ensure redirect URI is added: com.aether.courier://oauth2redirect/microsoft")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var syncTab: some View {
        Form {
            Section("Notifications") {
                Picker("New-mail sound", selection: $draft.notificationSound) {
                    ForEach(CourierSettings.availableSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: draft.notificationSound) { _, name in
                    if name != "None", let s = NSSound(named: NSSound.Name(name)) { s.play() }
                }
                Text("Plays a macOS system sound when new mail arrives. Choose “None” for silent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Automatically load remote images in all emails", isOn: $draft.loadRemoteImages)
                Text("Off by default: remote images (often used as tracking pixels) are blocked until you tap “Show Images” on a message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sync") {
                Label("New mail arrives instantly over IMAP IDLE — the app never polls.",
                      systemImage: "bolt.fill")
                Label("Folders sync their full history by default. Set a per-account limit in the Accounts tab if a mailbox is very large.",
                      systemImage: "clock.arrow.circlepath")
            }
            .labelStyle(.titleAndIcon)
        }
        .formStyle(.grouped)
    }

    private var blockedTab: some View {
        Form {
            Section("Block a Sender") {
                HStack {
                    TextField("email@example.com", text: $newBlock)
                    Button("Block") {
                        store.blockSender(newBlock); newBlock = ""
                    }
                    .disabled(!newBlock.contains("@"))
                }
                Text("Blocked senders' current and future mail is moved to Junk on every sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Blocked Senders (\(store.settings.blockedSenders.count))") {
                if store.settings.blockedSenders.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(store.settings.blockedSenders, id: \.self) { addr in
                    HStack {
                        Image(systemName: "nosign").foregroundStyle(.red)
                        Text(addr)
                        Spacer()
                        Button("Unblock") { store.unblockSender(addr); draft.blockedSenders = store.settings.blockedSenders }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func persist() {
        // Keep the live blocklist (mutated via store.blockSender) — don't let the
        // stale draft overwrite it on close.
        draft.blockedSenders = store.settings.blockedSenders
        let backendToken = self.backendToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let googleSecret = self.googleSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if backendToken.isEmpty {
            Keychain.delete(account: "aether-backend-token")
        } else {
            Keychain.setString(backendToken, account: "aether-backend-token")
        }
        if googleSecret.isEmpty {
            Keychain.delete(account: "google-client-secret")
        } else {
            Keychain.setString(googleSecret, account: "google-client-secret")
        }
        store.applySettings(draft)
    }
}
