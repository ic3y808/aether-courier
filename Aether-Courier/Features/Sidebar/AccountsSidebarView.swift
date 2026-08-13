import SwiftUI
import EmailKit

/// The sidebar: a narrow account **rail** (avatars that pick the scope) beside a
/// **folder list** that shows either the unified view (with collapsible
/// per-account sections) or a single account's folders.
struct AccountsSidebarView: View {
    @Environment(CourierStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            AccountRail()
            Divider()
            FolderList()
        }
        .background { AuroraBackdrop(intensity: 0.55) }
    }
}

// MARK: - Left rail

private struct AccountRail: View {
    @Environment(CourierStore.self) private var store
    @Namespace private var railNamespace

    private var inactiveScopes: [CourierScope] {
        var list: [CourierScope] = [.all]
        for account in store.accounts {
            list.append(.account(account.id))
        }
        return list.filter { $0 != store.scope }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Current scope header: active avatar matched to top + vertical email label
            VStack(spacing: 8) {
                ScopeIcon(scope: store.scope, size: 40, isTopHeader: true)
                    .matchedGeometryEffect(id: store.scope, in: railNamespace)
                verticalLabel
            }
            // Clear the window's traffic-light controls: the rail is only 66pt
            // wide, so it sits directly under them — start its content below the
            // title-bar/toolbar band instead of at the very top.
            .padding(.top, 52)

            Spacer(minLength: 12)

            // Switcher: all remaining (inactive) scopes
            VStack(spacing: 14) {
                ForEach(inactiveScopes, id: \.self) { scope in
                    railButton(scope)
                }
            }
            .padding(.bottom, 18)
        }
        .frame(width: 66)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: store.scope)
    }

    private var verticalLabel: some View {
        ZStack {
            Text(scopeName(for: store.scope))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .id(store.scope)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .frame(width: 30, height: 180)
        .padding(.vertical, 8)
    }

    private func scopeName(for scope: CourierScope) -> String {
        switch scope {
        case .all: return "All Accounts"
        case .account(let id): return store.accounts.first { $0.id == id }?.emailAddress ?? "Account"
        }
    }

    private func railButton(_ scope: CourierScope) -> some View {
        let unread = scope == .all ? store.unifiedUnreadCount : {
            if case .account(let id) = scope { return store.unread(for: id) }
            return 0
        }()
        return Button {
            store.selectScope(scope)
        } label: {
            ScopeIcon(scope: scope, size: 34, isTopHeader: false)
                .matchedGeometryEffect(id: scope, in: railNamespace)
                // Unread badge on top
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 10, weight: .heavy)).monospacedDigit()
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.white))
                            .overlay(Capsule().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
                            .fixedSize()
                            .offset(x: 5, y: -5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 46, height: 44)
        }
        .buttonStyle(.plain)
        .help(scopeName(for: scope))
    }
}

/// A round icon for a scope: the Aether mark for All Accounts, a colored
/// initials avatar for a specific account.
private struct ScopeIcon: View {
    @Environment(CourierStore.self) private var store
    let scope: CourierScope
    let size: CGFloat
    let isTopHeader: Bool

    var body: some View {
        Group {
            switch scope {
            case .all:
                ZStack {
                    Circle().fill(Color.aetherAccent.gradient)
                    Image(systemName: "tray.2.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .overlay {
                    if isTopHeader {
                        Circle().strokeBorder(Color.aetherAccent, lineWidth: 2.5)
                            .frame(width: size + 6, height: size + 6)
                    }
                }
            case .account(let id):
                if let account = store.accounts.first(where: { $0.id == id }) {
                    AccountAvatarView(account: account)
                        .frame(width: size, height: size)
                        .overlay {
                            if isTopHeader {
                                Circle().strokeBorder(Color.aetherAccent, lineWidth: 2.5)
                                    .frame(width: size + 6, height: size + 6)
                            }
                        }
                } else {
                    Circle().fill(.gray).frame(width: size, height: size)
                }
            }
        }
    }
}

// MARK: - Folder list

private struct FolderList: View {
    @Environment(CourierStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(
            get: { store.selection },
            set: { if let sel = $0 {
                store.selection = sel
                store.selectedIDs = []
                store.ensureFolderLoaded(sel)   // lazy per-folder fetch
                if sel == .flagged { store.ensureFlaggedLoaded() }
            } }
        )) {
            switch store.scope {
            case .all:
                unifiedSection
                accountSections
            case .account(let id):
                if let account = store.accounts.first(where: { $0.id == id }) {
                    singleAccountFolders(account)
                }
            }
        }
        .listStyle(.sidebar)
        // Disable implicit animations on the list so row changes (section switch,
        // disclosure expand/collapse) never crossfade a row's text into the one
        // below it — the "All Inboxes"/"INBOX" ghosting.
        .transaction { $0.animation = nil }
        .scrollContentBackground(.hidden)   // show the felt behind the folder list
        .safeAreaInset(edge: .bottom) { addAccountBar }
        .alert("New Folder", isPresented: Binding(
            get: { store.folderPromptAccount != nil },
            set: { if !$0 { store.folderPromptAccount = nil } }
        )) {
            TextField("Folder name", text: $store.newFolderName)
            Button("Create") {
                if let account = store.folderPromptAccount {
                    store.createFolder(named: store.newFolderName, in: account)
                }
                store.folderPromptAccount = nil
            }
            Button("Cancel", role: .cancel) { store.folderPromptAccount = nil }
        } message: {
            Text("Create a new folder in \(store.folderPromptAccount?.displayName ?? "this account").")
        }
    }

    // Unified "All Inboxes" row.
    @ViewBuilder private var unifiedSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "tray.full").frame(width: 18)
                Text("All Inboxes")
                Spacer()
                if store.unifiedUnreadCount > 0 {
                    Text("\(store.unifiedUnreadCount)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .tag(SidebarSelection.unifiedInbox)

            HStack(spacing: 6) {
                Image(systemName: "star.fill").foregroundStyle(.yellow).frame(width: 18)
                Text("Flagged")
                Spacer()
                if store.flaggedCount > 0 {
                    Text("\(store.flaggedCount)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .tag(SidebarSelection.flagged)
        }
    }

    // One collapsible section per account, preceded by an expand/collapse-all row.
    @ViewBuilder private var accountSections: some View {
        Section {
            HStack {
                Text("ACCOUNTS").font(.caption2).foregroundStyle(.secondary).kerning(0.5)
                Spacer()
                Button { store.toggleExpandAll() } label: {
                    Image(systemName: store.allExpanded ? "chevron.up.square" : "chevron.down.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(store.allExpanded ? "Collapse all accounts" : "Expand all accounts")
            }
        }
        ForEach(store.accounts) { account in
            Section {
                DisclosureGroup(isExpanded: Binding(
                    get: { store.expandedAccounts.contains(account.id) },
                    set: { _ in store.toggleExpanded(account.id) }
                )) {
                    ForEach(store.foldersToShow(for: account.id)) { folder in
                        folderRow(account: account, folder: folder)
                            .tag(SidebarSelection.folder(accountID: account.id, path: folder.path))
                    }
                } label: {
                    HStack(spacing: 8) {
                        AccountAvatarView(account: account)
                            .frame(width: 20, height: 20)
                        Text(account.displayName).lineLimit(1)
                        Spacer()
                        if store.unread(for: account.id) > 0 {
                            Text("\(store.unread(for: account.id))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    // Let the whole label toggle the section, not just the chevron.
                    .contentShape(Rectangle())
                    .onTapGesture { store.toggleExpanded(account.id) }
                    // Account menu lives on the HEADER only — attaching it to the
                    // DisclosureGroup made it swallow the folder rows' own menus.
                    .contextMenu {
                        Button("Show Only This Account") { store.selectScope(.account(account.id)) }
                        Button("New Folder…", systemImage: "folder.badge.plus") {
                            store.newFolderName = ""; store.folderPromptAccount = account
                        }
                        Button("Re-authenticate Account") { store.reauthenticateAccount(account) }
                        Divider()
                        Button("Remove Account", role: .destructive) { store.removeAccount(account) }
                    }
                }
            }
        }
    }

    // Single-account scope: just this account's folders.
    @ViewBuilder private func singleAccountFolders(_ account: MailAccount) -> some View {
        Section {
            ForEach(store.foldersToShow(for: account.id)) { folder in
                folderRow(account: account, folder: folder)
                    .tag(SidebarSelection.folder(accountID: account.id, path: folder.path))
            }
        }
    }

    private func folderRow(account: MailAccount, folder: MailFolder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: folderIcon(folder.role)).frame(width: 18)
            Text(folder.displayName)
            Spacer()
            let unread = (store.messagesByAccount[account.id] ?? [])
                .filter { $0.folderPath == folder.path && $0.isUnread }.count
            if unread > 0 { Text("\(unread)").foregroundStyle(.secondary).monospacedDigit() }
        }
        .contextMenu {
            Button("New Folder…", systemImage: "folder.badge.plus") {
                store.newFolderName = ""; store.folderPromptAccount = account
            }
            if folder.role == .junk || folder.role == .trash {
                Divider()
                Button(folder.role == .junk ? "Empty Spam" : "Empty Trash",
                       systemImage: "xmark.bin", role: .destructive) {
                    store.emptyFolder(account, folder: folder)
                }
            }
            if store.canDeleteFolder(folder) {
                Divider()
                Button("Delete Folder", systemImage: "trash", role: .destructive) {
                    store.deleteFolder(folder, in: account)
                }
            }
        }
    }

    private var addAccountBar: some View {
        Button { store.isAddingAccount = true } label: {
            Label("Add Account", systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func folderIcon(_ role: FolderRole) -> String {
        switch role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .archive: return "archivebox"
        case .flagged: return "flag"
        case .all: return "tray.2"
        case .other: return "folder"
        }
    }
}
