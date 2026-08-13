import SwiftUI
import WebKit
import AppKit
import EmailKit

/// Right-of-list detail pane: message header (fixed) + body that fills the rest.
/// HTML bodies render in a WKWebView with remote images blocked by default
/// (privacy); a "Show images" bar loads them per-message.
struct ReadingPaneView: View {
    @Environment(CourierStore.self) private var store
    @State private var showImages = false
    @State private var showDetails = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AuroraBackdrop() }   // cohesive felt behind the whole pane
    }

    @ViewBuilder
    private var content: some View {
        if let message = store.selectedMessage {
            VStack(alignment: .leading, spacing: 0) {
                header(message).padding(20)
                Divider()
                bodyView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onChange(of: store.selectedMessageID) { showImages = false; showDetails = false }
        } else if store.selectedIDs.count > 1 {
            FancyEmptyState(title: "\(store.selectedIDs.count) Messages Selected",
                            message: "Use the bulk actions above the list, or right-click, to manage them.",
                            systemImage: "checklist")
        } else {
            FancyEmptyState(title: "No Message Selected",
                            message: "Choose a message to read it here.",
                            systemImage: "envelope.open")
        }
    }

    private func header(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                    .font(.title2).fontWeight(.semibold).textSelection(.enabled)

                folderBadge(message)

                Spacer()
                messageActions(message)
                Button { store.toggleFlagged(message) } label: {
                    Image(systemName: message.flags.contains(.flagged) ? "star.fill" : "star")
                        .foregroundStyle(message.flags.contains(.flagged) ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(message.flags.contains(.flagged) ? "Unstar" : "Star")
            }
            HStack(spacing: 10) {
                AvatarView(label: message.from.first?.shortLabel ?? "?", seed: message.from.first?.address ?? "")
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    let sender = message.from.first
                    Text(sender?.name?.isEmpty == false ? sender!.name! : (sender?.address ?? "Unknown"))
                        .fontWeight(.medium)
                    // Always surface the sender's actual email address.
                    if let email = sender?.address, !email.isEmpty, email != sender?.name {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(1)
                    }
                    Text("to " + message.to.map(\.shortLabel).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let date = message.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(showDetails ? "Hide details" : "Details")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showDetails ? 180 : 0))
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(showDetails ? "Hide message details" : "Show message details")
                }
            }
            if showDetails { detailsSection(message) }
        }
    }

    /// Expandable "details" panel: full From/To/Cc, exact date, mailbox, size.
    private func detailsSection(_ m: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("From", addressList(m.from))
            if !m.to.isEmpty { detailRow("To", addressList(m.to)) }
            if !m.cc.isEmpty { detailRow("Cc", addressList(m.cc)) }
            detailRow("Subject", m.subject.isEmpty ? "(No subject)" : m.subject)
            if let date = m.date {
                detailRow("Date", date.formatted(date: .complete, time: .standard))
            }
            detailRow("Mailbox", store.folderDisplayName(for: m))
            if let size = m.sizeBytes {
                detailRow("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(corner: 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(value)
                .font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Display Name <email>" for each address, comma-separated.
    private func addressList(_ addrs: [MailAddress]) -> String {
        addrs.map { a in
            if let n = a.name, !n.isEmpty { return "\(n) <\(a.address)>" }
            return a.address
        }.joined(separator: ", ")
    }

    private func folderBadge(_ message: MailMessage) -> some View {
        let role = store.folderRole(for: message)
        let name = store.folderDisplayName(for: message)
        let isBlocked = store.isBlocked(message.from.first?.address ?? "")
        return HStack(spacing: 6) {
            if isBlocked {
                HStack(spacing: 3) {
                    Image(systemName: "hand.raised.fill")
                    Text("Blocked Sender")
                }
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.red))
            }
            HStack(spacing: 4) {
                Image(systemName: roleIcon(role))
                Text(name)
            }
            .font(.caption).fontWeight(.medium)
            .foregroundStyle(roleColor(role))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(roleColor(role).opacity(0.12)))
        }
    }

    private func roleIcon(_ role: FolderRole) -> String {
        switch role {
        case .inbox: return "tray.fill"
        case .junk: return "xmark.bin.fill"
        case .trash: return "trash.fill"
        case .archive: return "archivebox.fill"
        case .sent: return "paperplane.fill"
        case .drafts: return "pencil.circle.fill"
        default: return "tray.fill"
        }
    }

    private func roleColor(_ role: FolderRole) -> Color {
        switch role {
        case .inbox: return .aetherAccent
        case .junk: return .red
        case .trash: return .secondary
        case .archive: return .blue
        case .sent: return .purple
        case .drafts: return .orange
        default: return .aetherAccent
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        if store.isLoadingBody {
            VStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary).padding(.top, 6) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let body = store.openBody {
            VStack(spacing: 0) {
                if !body.attachments.isEmpty {
                    attachmentsRow(body.attachments).padding(.horizontal, 20).padding(.vertical, 10)
                    Divider()
                }
                if let html = body.html, !html.isEmpty {
                    VStack(spacing: 0) {
                        if blockRemote && Self.hasRemoteImages(html) { showImagesBar }
                        HTMLBodyView(html: html, blockRemote: blockRemote)
                    }
                    .paperSheet()
                } else {
                    ScrollView {
                        Text(body.plainText ?? body.bestText)
                            .font(.body).textSelection(.enabled)
                            .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                    .paperSheet()
                }
            }
        } else {
            Color.clear
        }
    }

    private var blockRemote: Bool {
        !(store.settings.loadRemoteImages || showImages)
    }

    private var showImagesBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
            Text("Remote images are blocked for your privacy.").font(.callout)
            Spacer()
            Button("Show Images") { showImages = true }
            Button("Always Load") {
                var s = store.settings; s.loadRemoteImages = true; store.applySettings(s)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
    }

    static func hasRemoteImages(_ html: String) -> Bool {
        for needle in ["src=\"http", "src='http", "url(http", "url(\"http", "background=\"http"] {
            if html.range(of: needle, options: .caseInsensitive) != nil { return true }
        }
        return false
    }

    private func attachmentsRow(_ attachments: [MailAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(attachments) { att in
                Label("\(att.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(att.sizeBytes), countStyle: .file))",
                      systemImage: "paperclip")
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Message actions live in the reading-pane header (not the window toolbar)
    /// so the toolbar never overflows at narrow widths.
    @ViewBuilder
    private func messageActions(_ message: MailMessage) -> some View {
        HStack(spacing: 4) {
            Button { store.reply(to: message, all: false) } label: { Image(systemName: "arrowshape.turn.up.left") }
                .help("Reply")
            Button { store.archive(message) } label: { Image(systemName: "archivebox") }
                .help("Archive")
            Button { store.trash(message) } label: { Image(systemName: "trash") }
                .help("Trash")
            Menu {
                Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { store.reply(to: message, all: true) }
                Button("Forward", systemImage: "arrowshape.turn.up.right") { store.forward(message) }
                Divider()
                Button(message.isUnread ? "Mark as Read" : "Mark as Unread",
                       systemImage: "envelope") { store.setRead(message, message.isUnread) }
                Button(message.flags.contains(.flagged) ? "Unstar" : "Star",
                       systemImage: "star") { store.toggleFlagged(message) }
                Divider()
                Button("Report as Spam", systemImage: "xmark.bin.fill") { store.reportSpam(message) }
                Button("Security Check with Copilot", systemImage: "checkmark.shield") { store.securityCheckOpenEmail() }
                Button("Summarize with Copilot", systemImage: "sparkles") { store.summarizeOpenEmail() }
                Button("Unsubscribe with Copilot", systemImage: "xmark.octagon") { store.unsubscribeOpenEmail() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .imageScale(.large)
    }
}

private extension View {
    /// Presents email content as a light "paper" sheet resting on the felt:
    /// warm paper background, soft rounded corners, a hairline edge and drop
    /// shadow, with a felt margin around it. Keeps email text readable in the
    /// app's dark theme (emails are authored for light backgrounds).
    func paperSheet() -> some View {
        self
            // Warm taupe mid-tone — sits between the green felt and white, not
            // stark; matches the email body CSS background (#ada388). Dark email
            // text stays readable on it.
            .background(Color(red: 0.678, green: 0.639, blue: 0.533))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 6)
            .padding(14)
    }
}

/// Opens clicked links (and target=_blank links) in the user's default browser
/// instead of navigating inside the email body view. Declared at file scope (NOT
/// nested in the NSViewRepresentable) so its @objc WKNavigationDelegate methods
/// are reliably visible to WebKit's respondsToSelector check on macOS 26.
final class HTMLLinkCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var pendingWebViews: [WKWebView] = []

    /// Internal WebKit schemes used exclusively for loading/rendering the email body and inline assets.
    private static let internalSchemes: Set<String> = ["about", "applewebdata", "data", "blob"]

    /// Checks if a navigation action is an external link click and opens it in macOS default browser (Chrome).
    private func openExternally(_ navigationAction: WKNavigationAction) -> Bool {
        guard let url = navigationAction.request.url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""

        // Internal document and inline resource loads are allowed inside WKWebView.
        if Self.internalSchemes.contains(scheme) || scheme.isEmpty {
            return false
        }

        // ANY external scheme (http, https, mailto, tel, facetime, etc.) opens in the user's OS default browser.
        let success = NSWorkspace.shared.open(url)
        logInfo("link: intercepted external navigation type=\(navigationAction.navigationType.rawValue) scheme=\(scheme) url=\(url.absoluteString) → default browser (success=\(success))", category: "link")
        return true
    }

    // Modern variant (macOS 11+/Tahoe) — WebKit calls THIS when implemented.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if openExternally(navigationAction) {
            pendingWebViews.removeAll { $0 == webView }
            decisionHandler(.cancel, preferences)
        } else {
            decisionHandler(.allow, preferences)
        }
    }

    // Legacy variant — for older runtimes.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if openExternally(navigationAction) {
            pendingWebViews.removeAll { $0 == webView }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if !scheme.isEmpty && !Self.internalSchemes.contains(scheme) {
                let success = NSWorkspace.shared.open(url)
                logInfo("link: createWebView (target=_blank) url=\(url.absoluteString) → default browser (success=\(success))", category: "link")
                return nil
            }
        }

        // Create & retain temporary WKWebView so ARC does not deallocate it before decidePolicyFor runs.
        logInfo("link: createWebView (target=_blank) creating & retaining temporary WKWebView", category: "link")
        let tempWebView = WKWebView(frame: .zero, configuration: configuration)
        tempWebView.navigationDelegate = self
        pendingWebViews.append(tempWebView)
        return tempWebView
    }
}

/// WKWebView host for an email's HTML body. JavaScript disabled; when
/// `blockRemote` is true a content-rule list blocks all http(s) subresources
/// (remote images/trackers), leaving inline data: images intact.
private struct HTMLBodyView: NSViewRepresentable {
    let html: String
    let blockRemote: Bool

    func makeCoordinator() -> HTMLLinkCoordinator { HTMLLinkCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false   // no in-app Safari-style link preview popover
        logInfo("link: makeNSView webview created, navDelegate=\(view.navigationDelegate != nil) uiDelegate=\(view.uiDelegate != nil)", category: "link")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.navigationDelegate == nil { view.navigationDelegate = context.coordinator }
        if view.uiDelegate == nil { view.uiDelegate = context.coordinator }

        // Render on a light "paper" sheet (like Apple Mail) so email text — which
        // is almost always authored for a white background — stays readable
        // regardless of the app's dark theme. color-scheme:light stops WebKit from
        // auto-darkening; an explicit dark default color fixes emails that rely on
        // the (previously canvastext) default and would otherwise be dark-on-dark.
        let wrapped = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <!-- Force every link to a new window: clicks route through the coordinator's
             new-window / navigation handlers, which open the OS default browser. -->
        <base target="_blank">
        <style>
          :root { color-scheme: light; }
          html, body { background: #e3e1ee; }
          body { font: -apple-system-body; font-family: -apple-system, system-ui;
                 margin: 20px; color: #1b1a24; min-height: calc(100vh - 40px);
                 -webkit-text-size-adjust: 100%; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
          a { color: #0a5bbf; }
          table { max-width: 100% !important; }
        </style></head><body>\(html)</body></html>
        """
        view.configuration.userContentController.removeAllContentRuleLists()
        if blockRemote {
            Task { @MainActor in
                if let rule = await Self.remoteBlockRule() {
                    view.configuration.userContentController.add(rule)
                }
                view.loadHTMLString(wrapped, baseURL: nil)
            }
        } else {
            view.loadHTMLString(wrapped, baseURL: nil)
        }
    }

    /// Compiled rule that blocks all http(s) subresources (remote images/
    /// trackers), cached after first compile. Inline data: images still load.
    @MainActor private static var cachedRule: WKContentRuleList?
    @MainActor private static func remoteBlockRule() async -> WKContentRuleList? {
        if let cachedRule { return cachedRule }
        let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        let rule = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "aether-block-remote", encodedContentRuleList: json)
        cachedRule = rule
        return rule
    }
}
