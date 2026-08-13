import Foundation
import EmailKit

/// One context-aware Copilot action, derived locally (no LLM) from the open email.
struct CopilotSuggestion: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let run: () -> Void
}

extension CourierStore {

    // MARK: - Content-aware suggestions

    /// Suggestions tuned to whatever email is currently open. Pure local heuristics
    /// over the envelope + (when loaded) the body — cheap, runs on every selection.
    /// The chips it returns drive both the Copilot's contextual panel and the
    /// auto show/hide behaviour below.
    var contextualSuggestions: [CopilotSuggestion] {
        guard let m = selectedMessage else { return [] }

        let subject = m.subject.lowercased()
        let sender  = (m.from.first?.address ?? "").lowercased()
        let body    = (selectedMessageID == m.id ? openBody?.bestText : nil)?.lowercased() ?? ""
        let hay     = subject + "\n" + m.snippet.lowercased() + "\n" + body
        func has(_ needles: [String]) -> Bool { needles.contains { hay.contains($0) } }

        let isNewsletter = has(["unsubscribe", "manage your preferences", "manage preferences",
                                "view in browser", "email preferences", "you are receiving this"])
                           || sender.hasPrefix("no-reply") || sender.hasPrefix("noreply")
                           || sender.contains("newsletter") || sender.contains("marketing")
        let isReceipt    = has(["receipt", "invoice", "order #", "order confirmation", "your order",
                                "payment received", "you paid", "your subscription", "billed", "amount due"])
        let isMeeting    = has(["invitation:", "when:", " rsvp", "calendar invite", "zoom.us",
                                "meet.google", "teams.microsoft", "webex", ".ics", "google calendar"])
                           || (subject.contains("meeting") && has(["join", "invite", "calendar"]))
        let isSuspicious = has(["verify your account", "verify your identity", "unusual sign-in",
                                "account has been suspended", "confirm your password", "update your payment",
                                "account locked", "your account will be", "security alert", "click here to verify"])

        var out: [CopilotSuggestion] = []
        var ids = Set<String>()
        func add(_ id: String, _ title: String, _ image: String, _ run: @escaping () -> Void) {
            guard ids.insert(id).inserted else { return }
            out.append(CopilotSuggestion(id: id, title: title, systemImage: image, run: run))
        }

        // Ordered by relevance; the always-on pair (summarize/reply) bracket the
        // content-specific chips so a strong signal is never trimmed by the cap.
        add("summarize", "Summarize this email", "text.append") { [weak self] in self?.summarizeOpenEmail() }

        if isSuspicious {
            add("security", "Is this safe?", "checkmark.shield") { [weak self] in self?.securityCheckOpenEmail() }
        }
        if isMeeting {
            add("availability", "Check my availability", "calendar") { [weak self] in
                guard let self else { return }
                self.isCopilotVisible = true
                self.runQuickAction(.availability)
            }
        }
        if let folder = suggestedFolder(for: m) {
            add("move", "Move to “\(folder.displayName)”", "folder") { [weak self] in
                self?.moveToFolder(m, path: folder.path)
            }
        }
        if isNewsletter {
            add("unsubscribe", "Unsubscribe from this", "xmark.octagon") { [weak self] in self?.unsubscribeOpenEmail() }
        }

        add("reply", "Draft a reply", "arrowshape.turn.up.left") { [weak self] in self?.draftReplyOpenEmail() }

        if isNewsletter || isReceipt {
            add("delete-sender", "Delete all from this sender", "trash.slash") { [weak self] in self?.deleteAllFromSenderOpenEmail() }
        }

        return Array(out.prefix(5))
    }

    /// A content signal beyond the always-on summarize/reply pair. Drives auto-reveal.
    var hasStrongCopilotContext: Bool {
        contextualSuggestions.contains { !["summarize", "reply"].contains($0.id) }
    }

    /// A custom (`.other`) folder in the same account whose leaf name resembles the
    /// sender's org or domain — e.g. mail from `billing@vela.com` → a “Vela” folder.
    func suggestedFolder(for m: MailMessage) -> MailFolder? {
        let tokens = senderTokens(for: m)
        guard !tokens.isEmpty else { return nil }
        return foldersToShow(for: m.accountID).first { f in
            guard f.role == .other, f.isSelectable, f.path != m.folderPath else { return false }
            let name = f.displayName.lowercased()
            return tokens.contains { name.contains($0) || $0.contains(name) }
        }
    }

    /// Distinctive lowercased tokens from the sender's display name and domain,
    /// dropping generic words that would over-match ("mail", "team", "info"…).
    private func senderTokens(for m: MailMessage) -> [String] {
        guard let addr = m.from.first else { return [] }
        let stop: Set<String> = ["mail", "email", "team", "info", "no", "reply", "noreply",
                                 "support", "hello", "hi", "account", "accounts", "notifications",
                                 "the", "and", "com", "net", "org", "io", "co", "inc", "llc"]
        var tokens: [String] = []
        if let name = addr.name?.lowercased() {
            tokens += name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        // Second-level domain label, e.g. "vela" from "billing@mail.vela.com".
        if let at = addr.address.split(separator: "@").last {
            let labels = at.split(separator: ".").map(String.init)
            if labels.count >= 2 { tokens.append(labels[labels.count - 2].lowercased()) }
        }
        return tokens.filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// Draft (not send) a reply to the open email, shown in the Copilot thread.
    func draftReplyOpenEmail() {
        guard selectedMessage != nil else {
            copilotTurns.append(CopilotTurn(role: .assistant, text: "Open an email first — then I'll draft a reply."))
            return
        }
        isCopilotVisible = true
        runCopilot("Draft a concise, friendly reply to the currently open email. Return only the reply text — do not send it.")
    }

    // MARK: - Auto show / hide

    /// Manual show/hide (toolbar button, ⌘J, the pane's own close button). Once the
    /// user takes control we stop auto-managing visibility for the session.
    func userSetCopilotVisible(_ visible: Bool) {
        isCopilotVisible = visible
        copilotUserPinned = true
        copilotAutoShown = false
    }

    /// Reveal the Copilot when the open email has a strong, actionable signal; and
    /// retract it again when that signal goes away — but only ever touch a pane we
    /// auto-revealed, and never once the user has taken manual control.
    func syncCopilotVisibility() {
        guard settings.autoRevealCopilot, !copilotUserPinned else { return }
        if hasStrongCopilotContext {
            if !isCopilotVisible {
                isCopilotVisible = true
                copilotAutoShown = true
            }
        } else if copilotAutoShown {
            isCopilotVisible = false
            copilotAutoShown = false
        }
    }
}
