import SwiftUI

/// The AI Copilot inspector pane. Greets the user, offers quick-action chips
/// (Compose, Search, Tasks, Availability, Help), shows the conversation, and
/// takes free-form prompts. All AI runs through the Aether backend.
struct CopilotView: View {
    @Environment(CourierStore.self) private var store
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.copilotTurns.isEmpty {
                            if store.selectedMessage != nil { contextSection } else { emptyGreeting }
                        }
                        ForEach(store.copilotTurns) { turn in
                            CopilotBubble(turn: turn).id(turn.id)
                        }
                        if store.copilotBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                                Button { store.stopCopilot() } label: {
                                    Label("Stop", systemImage: "stop.circle.fill")
                                }
                                .buttonStyle(.plain).foregroundStyle(.red).font(.caption)
                                .help("Stop thinking")
                            }
                        }
                    }
                    .padding(14)
                }
                .onChange(of: store.copilotTurns.count) {
                    if let last = store.copilotTurns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            composer
        }
        .background { AuroraBackdrop(intensity: 0.7) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { store.userSetCopilotVisible(false) } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Hide Copilot (⌘J)")
            Label("Copilot", systemImage: "sparkles").font(.headline)
            Spacer()
            Menu {
                Button("Summarize Unread & Flag Important", systemImage: "tray.full") { store.summarizeUnread() }
                Button("Organize & Triage Everything", systemImage: "wand.and.rays") { store.organizeEverything() }
                Button("Summarize This Email", systemImage: "text.append") { store.summarizeOpenEmail() }
                Button("Unsubscribe from This Email", systemImage: "xmark.octagon") { store.unsubscribeOpenEmail() }
                Button("Security Check This Email", systemImage: "checkmark.shield") { store.securityCheckOpenEmail() }
                Button("Report This Email as Spam", systemImage: "xmark.bin.fill") { store.reportSpamOpenEmail() }
                Button("Delete All from This Sender", systemImage: "trash.slash") { store.deleteAllFromSenderOpenEmail() }
                Button("Sort Inboxes into Folders", systemImage: "arrow.triangle.branch") { store.sortInboxesIntoFolders() }
                Divider()
                Button("Empty Trash (All Accounts)", systemImage: "trash", role: .destructive) { store.emptyTrash() }
                Button("Empty Spam (All Accounts)", systemImage: "xmark.bin", role: .destructive) { store.emptySpam() }
                Button("Compose New Email", systemImage: "square.and.pencil") { store.beginCompose() }
                Button("Show Availability", systemImage: "calendar") { store.runQuickAction(.availability) }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Quick actions")
            Button { store.copilotTurns.removeAll() } label: { Text("Clear").font(.callout) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var emptyGreeting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Spacer(); GlowOrb(systemImage: "sparkles", size: 76); Spacer() }
                .padding(.top, 6).padding(.bottom, 2)
            Text("Hi \(NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"), what would you like to do today?")
                .font(.callout).fontWeight(.medium)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient.aetherAccent.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))

            Text("ASSISTANT").font(.caption2).foregroundStyle(.secondary).kerning(1.5)
            ForEach(CopilotQuickAction.allCases, id: \.self) { action in
                Button { store.runQuickAction(action) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LinearGradient.aetherAccent)
                            .frame(width: 20)
                        Text(action.title)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 13)
                    .glassCard(corner: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Content-aware panel: what the Copilot can do for the email that's open now.
    /// Its chips (and the whole pane's visibility) react to the email's content.
    @ViewBuilder private var contextSection: some View {
        if let m = store.selectedMessage {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    GlowOrb(systemImage: "sparkles", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("For this email").font(.caption2).foregroundStyle(.secondary).kerning(1.2)
                        Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                            .font(.callout).fontWeight(.semibold).lineLimit(2)
                        Text(m.from.first?.shortLabel ?? "unknown sender")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient.aetherAccent.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))

                Text("SUGGESTED").font(.caption2).foregroundStyle(.secondary).kerning(1.5)
                ForEach(store.contextualSuggestions) { s in
                    Button { s.run() } label: {
                        HStack(spacing: 11) {
                            Image(systemName: s.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LinearGradient.aetherAccent)
                                .frame(width: 20)
                            Text(s.title)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10).padding(.horizontal, 13)
                        .glassCard(corner: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask me anything…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit(submit)
            if store.copilotBusy {
                Button(action: store.stopCopilot) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop thinking")
            } else {
                let empty = input.trimmingCharacters(in: .whitespaces).isEmpty
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(empty ? AnyShapeStyle(Color.secondary.opacity(0.35))
                                          : AnyShapeStyle(LinearGradient.aetherAccent), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(empty)
            }
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private func submit() {
        let text = input
        input = ""
        store.runAgent(text)   // agentic: the model can take actions via tools
    }
}

private struct CopilotBubble: View {
    let turn: CopilotTurn

    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 24) }
            Group {
                if turn.role == .assistant {
                    // Rich Markdown for assistant replies.
                    MarkdownView(turn.text)
                        .textSelection(.enabled)
                        .foregroundStyle(Color.primary)
                } else {
                    Text(turn.text)
                        .textSelection(.enabled)
                        .foregroundStyle(Color.white)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background {
                if turn.role == .user {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(LinearGradient.aetherAccent)
                } else {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.10)))
                }
            }
            .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
            if turn.role == .assistant { Spacer(minLength: 24) }
        }
    }
}
