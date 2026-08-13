import SwiftUI

/// Aether-Courier — a native macOS 26 email client for the Aether AI Hub.
///
/// The mail engine (IMAP/SMTP/MIME/OAuth) lives entirely in the local EmailKit
/// package; the Aether backend is used ONLY for AI copilot tasks via
/// `CourierAIClient`. New mail arrives over IMAP IDLE — the app never polls.
@main
struct AetherCourierApp: App {
    @State private var store = CourierStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                // Wide enough to fit all four panes (rail+list | reading |
                // copilot) at their minimums without clipping the sidebars.
                .frame(minWidth: 1220, minHeight: 620)
                .task { await store.bootstrap() }
        }
        // Standard title bar (unified toolbar) so the window traffic-light
        // controls sit in their own strip instead of floating over the sidebar.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Message") { store.beginCompose() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Add Account…") { store.isAddingAccount = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button(store.isCopilotVisible ? "Hide Copilot" : "Show Copilot") {
                    store.userSetCopilotVisible(!store.isCopilotVisible)
                }
                .keyboardShortcut("j", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .frame(width: 620, height: 460)
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}
