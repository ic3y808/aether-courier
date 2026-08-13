import SwiftUI
import EmailKit

/// Middle pane: the scrollable message list for the current selection, with
/// sender avatar, subject, snippet, and a relative timestamp.
struct MessageListView: View {
    @Environment(CourierStore.self) private var store
    @State private var searchText = ""

    /// Client-side filter over the cached messages for the current selection & active filter.
    private var messages: [MailMessage] {
        var pool = store.displayedMessages
        if store.activeFilter != .primary {
            // Keep the currently-open message(s) even after they stop matching —
            // e.g. an unread mail that clicking just marked read shouldn't vanish
            // mid-read. They drop once the user selects a different message or
            // switches box/filter (both re-evaluate this pool).
            let sticky = store.selectedIDs
            pool = pool.filter { store.activeFilter.matches($0) || sticky.contains($0.id) }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return pool }
        return pool.filter { m in
            m.subject.lowercased().contains(q)
                || m.from.contains { $0.address.lowercased().contains(q) || ($0.name?.lowercased().contains(q) ?? false) }
        }
    }

    private var unreadCount: Int {
        store.displayedMessages.filter(\.isUnread).count
    }

    var body: some View {
        VStack(spacing: 0) {
            listHeader
            filterTabBar
            if store.showFilterBanner, let bannerText = store.activeFilter.descriptionBanner {
                filterBanner(text: bannerText)
            }
            searchField
            if store.selectedIDs.count > 1 { bulkBar }
            Divider()
            Group {
                // Observe the folder map so the rows (and their "Move to Folder"
                // context submenus) rebuild when a folder is added/removed —
                // otherwise only the sidebar, which reads it, picks up the change.
                let _ = store.foldersByAccount
                if messages.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: Binding(
                        get: { store.selectedIDs },
                        set: { store.selectedIDs = $0; store.loadBodyForSelection() }
                    )) {
                        ForEach(messages) { message in
                            MessageRow(message: message)
                                .tag(message.id)
                                .listRowBackground(Color.clear)
                                .contextMenu { messageMenu(message) }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)   // let the felt show through
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { AuroraBackdrop(intensity: 0.6) }
    }

    /// Header matching user's design: Title + Subtitle ("Primary · 74 messages, 8 unread") + Filter menu button
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.title2).fontWeight(.bold).lineLimit(1)
                if store.isSyncing || store.isSearchingFlagged {
                    ProgressView().controlSize(.small)
                }
                Spacer()

                // Filter Menu Button
                Menu {
                    Section("All Message Filters") {
                        ForEach(MessageFilter.allCases) { filter in
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    store.selectFilter(filter)
                                }
                            } label: {
                                Label(filter.title, systemImage: filter.iconName)
                            }
                        }
                    }
                    if store.activeFilter != .primary {
                        Divider()
                        Button("Reset to Primary", systemImage: "xmark.circle") {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                store.selectFilter(.primary)
                            }
                        }
                    }
                } label: {
                    Image(systemName: store.activeFilter == .primary ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(store.activeFilter == .primary ? Color.primary.opacity(0.8) : store.activeFilter.accentColor)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Filter Messages")

                if store.selection == .flagged {
                    Button { store.refreshFlagged() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(store.isSearchingFlagged)
                        .help("Search all folders for flagged messages")
                }
            }

            Text("\(store.activeFilter.title) · \(messages.count) message\(messages.count == 1 ? "" : "s"), \(unreadCount) unread")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Horizontal tab bar for frequently used filters. Automatically ranks & populates filters based on usage.
    private var filterTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.frequentlyUsedFilters) { filter in
                    let isSelected = store.activeFilter == filter
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            store.selectFilter(filter)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: filter.iconName)
                                .font(.system(size: 14, weight: .semibold))
                            if isSelected {
                                Text(filter.title)
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                        .padding(.horizontal, isSelected ? 16 : 10)
                        .frame(height: 34)
                        .background(
                            Capsule()
                                .fill(isSelected ? AnyShapeStyle(LinearGradient.aetherAccent)
                                                 : AnyShapeStyle(.ultraThinMaterial))
                        )
                        .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 0.18 : 0.10), lineWidth: 0.75))
                        .shadow(color: isSelected ? Color.aetherAccent.opacity(0.35) : .clear, radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    /// Interactive category description banner (matching user's Image 2 banner)
    private func filterBanner(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.activeFilter.bannerTitle)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(store.activeFilter.accentColor)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.85))
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.showFilterBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(store.activeFilter.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(store.activeFilter.accentColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(store.activeFilter.accentColor.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Bulk-action bar shown when 2+ messages are selected (⌘/shift-click, ⌘A).
    private var bulkBar: some View {
        HStack(spacing: 14) {
            Text("\(store.selectedIDs.count) selected").font(.callout).fontWeight(.medium)
            Spacer()
            Button { store.bulkMarkRead(true) } label: { Image(systemName: "envelope.open") }.help("Mark read")
            Button { store.bulkMarkRead(false) } label: { Image(systemName: "envelope.badge") }.help("Mark unread")
            Button { store.bulkToggleStar() } label: {
                Image(systemName: store.allSelectedStarred ? "star.slash" : "star")
            }.help(store.allSelectedStarred ? "Unstar" : "Star")
            Button { store.bulkArchive() } label: { Image(systemName: "archivebox") }.help("Archive")
            Button { store.bulkSpam() } label: { Image(systemName: "xmark.bin") }.help("Mark as spam")
            Button { store.bulkTrash() } label: { Image(systemName: "trash") }.help("Trash")
            Button("Clear") { store.selectedIDs = [] }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.tint.opacity(0.12))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
            TextField("Search subject or sender", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .glassCard(corner: 10)
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    @ViewBuilder
    private func messageMenu(_ m: MailMessage) -> some View {
        // When right-clicking a row that's part of a multi-selection, the mutating
        // actions apply to the WHOLE selection; otherwise just this row.
        let isMulti = store.selectedIDs.count > 1 && store.selectedIDs.contains(m.id)
        let n = store.selectedIDs.count
        let suffix = isMulti ? " (\(n))" : ""

        Button(m.isUnread ? "Mark as Read\(suffix)" : "Mark as Unread\(suffix)",
               systemImage: m.isUnread ? "envelope.open" : "envelope.badge") {
            if isMulti { store.bulkMarkRead(m.isUnread) } else { store.setRead(m, m.isUnread) }
        }
        Button((m.flags.contains(.flagged) ? "Unstar" : "Mark as Starred") + suffix,
               systemImage: m.flags.contains(.flagged) ? "star.slash" : "star") {
            if isMulti { store.bulkStar(!m.flags.contains(.flagged)) } else { store.toggleFlagged(m) }
        }
        Divider()
        Button("Mark as Spam\(suffix)", systemImage: "xmark.bin") {
            if isMulti { store.bulkSpam() } else { store.move(m, toRole: .junk) }
        }
        if let addr = m.from.first?.address {
            if store.isBlocked(addr) {
                Button("Unblock Sender (\(m.from.first?.shortLabel ?? addr))", systemImage: "hand.raised.slash") {
                    store.unblockSender(addr)
                }
            } else {
                Button("Block Sender (\(m.from.first?.shortLabel ?? addr))", systemImage: "hand.raised.fill", role: .destructive) {
                    store.blockSender(addr)
                }
            }
        }
        Divider()
        let destinations = store.moveDestinations(for: m)
        if !destinations.isEmpty {
            Menu {
                ForEach(destinations) { folder in
                    Button(folder.displayName, systemImage: folderIcon(folder.role)) {
                        if isMulti { store.moveMessagesToFolder(store.selectedMessages, path: folder.path) }
                        else { store.moveToFolder(m, path: folder.path) }
                    }
                }
            } label: { Label("Move to Folder\(suffix)", systemImage: "folder") }
        }
        Button("Archive\(suffix)", systemImage: "archivebox") {
            if isMulti { store.bulkArchive() } else { store.archive(m) }
        }
        Button("Move to Trash\(suffix)", systemImage: "trash", role: .destructive) {
            if isMulti { store.bulkTrash() } else { store.trash(m) }
        }
        Divider()
        Button("Reply", systemImage: "arrowshape.turn.up.left") { store.reply(to: m, all: false) }
        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { store.reply(to: m, all: true) }
        Button("Forward", systemImage: "arrowshape.turn.up.right") { store.forward(m) }
        Divider()
        Button("Summarize with Copilot", systemImage: "sparkles") {
            store.selectMessage(m); store.summarizeOpenEmail()
        }
    }

    private func folderIcon(_ role: FolderRole) -> String {
        switch role {
        case .inbox:   return "tray"
        case .sent:    return "paperplane"
        case .drafts:  return "pencil"
        case .trash:   return "trash"
        case .junk:    return "xmark.bin"
        case .archive: return "archivebox"
        case .flagged: return "flag"
        case .all:     return "tray.full"
        case .other:   return "folder"
        }
    }

    private var title: String {
        switch store.selection {
        case .unifiedInbox: return "All Inboxes"
        case .flagged: return "Flagged"
        case .folder(let accountID, let path):
            let name = store.accounts.first { $0.id == accountID }?.displayName ?? "Mail"
            return "\(name) — \((path as NSString).lastPathComponent)"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            FancyEmptyState(title: store.accounts.isEmpty ? "No Accounts Yet" : "All Caught Up",
                            message: store.accounts.isEmpty
                                ? "Add an email account to start receiving mail."
                                : "This folder is empty or still syncing.",
                            systemImage: store.accounts.isEmpty ? "tray" : "checkmark.seal")
            if store.accounts.isEmpty {
                Button { store.isAddingAccount = true } label: {
                    Label("Add Account", systemImage: "plus")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .offset(y: -8)
            }
        }
    }
}

private struct MessageRow: View {
    @Environment(CourierStore.self) private var store
    let message: MailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(label: message.from.first?.shortLabel ?? "?", seed: message.from.first?.address ?? "")
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.from.first?.shortLabel ?? message.from.first?.address ?? "Unknown")
                        .font(.subheadline).fontWeight(message.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    
                    folderBadge

                    Spacer()
                    Text(relativeDate)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                    .font(.callout).fontWeight(message.isUnread ? .medium : .regular)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if message.hasAttachments {
                        Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(message.snippet.isEmpty ? " " : message.snippet)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if message.isUnread {
                Circle().fill(.blue).frame(width: 7, height: 7).padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
    }

    private var folderBadge: some View {
        let role = store.folderRole(for: message)
        let name = store.folderDisplayName(for: message)
        let isBlocked = store.isBlocked(message.from.first?.address ?? "")
        return HStack(spacing: 3) {
            if isBlocked {
                Text("Blocked")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(.red))
            }
            if role != .inbox {
                Text(name)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(badgeColor(role))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(badgeColor(role).opacity(0.15)))
            }
        }
    }

    private func badgeColor(_ role: FolderRole) -> Color {
        switch role {
        case .junk: return .red
        case .trash: return .secondary
        case .archive: return .blue
        case .sent: return .purple
        case .drafts: return .orange
        case .inbox: return .aetherAccent
        default: return .aetherAccent
        }
    }

    private var relativeDate: String {
        guard let date = message.date else { return "" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        if Calendar.current.isDateInToday(date) {
            let t = DateFormatter(); t.dateFormat = "h:mm a"; return t.string(from: date)
        }
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

/// A colored initials bubble. Uses `tint` when provided (e.g. a provider brand
/// color for account avatars), otherwise a deterministic per-seed color.
struct AvatarView: View {
    let label: String
    let seed: String
    var tint: Color? = nil

    var body: some View {
        Circle()
            .fill(color.gradient)
            .overlay(Text(initials).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
    }

    private var initials: String {
        let parts = label.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
    private var color: Color {
        if let tint { return tint }
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        let idx = abs(seed.hashValue) % palette.count
        return palette[idx]
    }
}
