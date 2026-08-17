import Foundation
import SwiftUI
import Observation
import EmailKit

/// Runs `op`, returning its result, or `def` if it doesn't finish within
/// `seconds` (cancelling it). Bounds IMAP ops that can hang on throttled servers.
func withDeadline<T: Sendable>(seconds: Double, default def: T,
                               _ op: @escaping @Sendable () async -> T) async -> T {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await op() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let winner: T? = (await group.next()) ?? nil
        group.cancelAll()
        return winner ?? def
    }
}

/// What the sidebar selection points at.
enum SidebarSelection: Hashable {
    case unifiedInbox
    case flagged
    case folder(accountID: UUID, path: String)
}

/// The account-rail scope: all accounts (unified) or one specific account.
enum CourierScope: Hashable {
    case all
    case account(UUID)
}

/// A prefilled compose draft (reply/forward) handed to ComposeView.
struct ComposeDraft: Equatable {
    var accountID: UUID
    var to: String = ""
    var cc: String = ""
    var subject: String = ""
    var body: String = ""
    var inReplyTo: String?
}

/// One turn in the copilot conversation.
struct CopilotTurn: Identifiable, Hashable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// The single source of truth for the UI. Owns the account list, the fetched
/// mail, the copilot conversation, and the service actors. `@MainActor` so all
/// view state mutation is main-thread; the actors it calls do the I/O.
@MainActor
@Observable
final class CourierStore {
    // Configuration + persistence
    var settings = CourierSettings.load()
    private let accountStore = AccountStore()

    // Data
    var accounts: [MailAccount] = []
    var foldersByAccount: [UUID: [MailFolder]] = [:]
    /// Flat per-account message store spanning every fetched folder (each
    /// message carries its `folderPath`). Folders load lazily on first open.
    var messagesByAccount: [UUID: [MailMessage]] = [:]
    /// The resolved INBOX path per account (for the unified inbox + badges).
    var inboxPath: [UUID: String] = [:]
    /// Which "accountID:folderPath" folders have already been fetched.
    var loadedFolders: Set<String> = []

    // Account rail scope + collapsible sections
    var scope: CourierScope = .all
    var expandedAccounts: Set<UUID> = []

    // Selection / reading
    var selection: SidebarSelection = .unifiedInbox
    /// Multi-selection of message ids (⌘/shift/⌘A in the list).
    var selectedIDs: Set<String> = []
    /// The single selected message id, or nil when 0 or many are selected.
    var selectedMessageID: String? { selectedIDs.count == 1 ? selectedIDs.first : nil }
    var openBody: MailBody?
    var isLoadingBody = false

    /// In-memory cache of fetched message bodies (keyed by message id) so
    /// re-opening a message is instant and never re-downloads. LRU-capped.
    @ObservationIgnored private var bodyCache: [String: MailBody] = [:]
    @ObservationIgnored private var bodyCacheOrder: [String] = []
    private let bodyCacheLimit = 400

    private func cacheBody(_ id: String, _ body: MailBody) {
        if bodyCache[id] == nil { bodyCacheOrder.append(id) }
        bodyCache[id] = body
        while bodyCacheOrder.count > bodyCacheLimit {
            let evicted = bodyCacheOrder.removeFirst()
            bodyCache[evicted] = nil
        }
    }

    // Message Filtering state
    var activeFilter: MessageFilter = .primary
    var filterUsageCounts: [MessageFilter: Int] = [
        .primary: 100,
        .shopping: 90,
        .social: 80,
        .promotions: 70,
        .unread: 60,
        .attachments: 50,
        .starred: 40,
        .vip: 30
    ]
    var showFilterBanner: Bool = true

    var frequentlyUsedFilters: [MessageFilter] {
        let sorted = MessageFilter.allCases.sorted {
            (filterUsageCounts[$0] ?? 0) > (filterUsageCounts[$1] ?? 0)
        }
        var result: [MessageFilter] = [.primary]
        for f in sorted where f != .primary {
            if result.count < 5 {
                result.append(f)
            }
        }
        return result
    }

    func selectFilter(_ filter: MessageFilter) {
        filterUsageCounts[filter, default: 0] += 1
        activeFilter = filter
        showFilterBanner = true
    }

    // UI flags
    var isCopilotVisible = true
    /// True once the user has manually shown/hidden the Copilot — after that we
    /// stop auto-managing its visibility for the session (their choice wins).
    @ObservationIgnored var copilotUserPinned = false
    /// True while the Copilot is on screen *because we auto-revealed it* — only
    /// such an auto-shown pane is auto-hidden again when context stops being relevant.
    @ObservationIgnored var copilotAutoShown = false
    var isAddingAccount = false
    var isComposing = false
    var isSyncing = false
    var banner: String?
    /// Prefilled draft for the compose window (reply/forward). nil = blank compose.
    var composeDraft: ComposeDraft?

    // Copilot
    var copilotTurns: [CopilotTurn] = []
    var copilotBusy = false

    /// Voicemail playback (Google Voice etc.) — see CopilotContext.
    var isPlayingVoicemail = false
    @ObservationIgnored let voicemailPlayer = VoicemailPlayer()
    /// The in-flight copilot/agent task, so the user can stop it mid-thought.
    @ObservationIgnored var copilotTask: Task<Void, Never>?

    /// Cancels the running copilot/agent request (the "stop thinking" button).
    func stopCopilot() {
        guard copilotBusy || copilotTask != nil else { return }
        copilotTask?.cancel()
        copilotTask = nil
        copilotBusy = false
        copilotTurns.append(CopilotTurn(role: .assistant, text: "⏹ Stopped."))
    }

    // Services (excluded from Observation — they hold no view state)
    @ObservationIgnored var mailService: MailService
    @ObservationIgnored var ai: CourierAIClient
    let calendar = CalendarService()

    // Persistence + background refresh
    @ObservationIgnored private let cache = MessageCache()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var warmerTask: Task<Void, Never>?
    @ObservationIgnored private var flaggedSearched = false
    var isSearchingFlagged = false

    init() {
        let loaded = CourierSettings.load()
        settings = loaded
        mailService = MailService(settings: loaded)
        ai = CourierAIClient(host: loaded.aiUseLocal ? loaded.localAIHost : loaded.backendHost,
                             model: loaded.aiModel,
                             sendToken: !loaded.aiUseLocal)
    }

    // MARK: lifecycle

    func bootstrap() async {
        accounts = accountStore.load()
        loadCache()   // show cached mail instantly, before the network sync
        logInfo("Bootstrap: loaded \(accounts.count) account(s); AI=\(settings.aiUseLocal ? settings.localAIHost : settings.backendHost) model=\(settings.aiModel)", category: "app")
        await loadModels()   // populate + auto-heal the copilot model
        await calendar.requestAccess()
        logInfo("Calendar access: \(calendar.authorized ? "granted" : "not granted")", category: "app")
        for account in accounts where account.isEnabled {
            await sync(account)
            startIdle(account)
        }
        startPeriodicRefresh()
        // Three INDEPENDENT background jobs (previously chained, so a slow/stalled
        // folder sync starved the warmer and it never ran):
        //  1. prefetch recent inbox bodies → instant open of recent mail;
        //  2. discover every folder so All Inboxes + filters see folder mail;
        //  3. the continuous full-cache warmer — starts immediately and caches
        //     everything it can see, re-sweeping as folders load in.
        Task(priority: .background) { for account in accounts where account.isEnabled { await prefetchBodies(for: account) } }
        Task(priority: .background) {
            for account in accounts where account.isEnabled { await syncAllFolders(account) }
            await mailService.pruneBodyCache()   // bound disk usage
        }
        startCacheWarmer()
        logInfo("Bootstrap complete. Log file: \(CourierLog.shared.fileURL.path)", category: "app")
    }

    // MARK: cache persistence

    private func loadCache() {
        guard let snap = cache.load() else { return }
        func keyed<V>(_ dict: [String: V]) -> [UUID: V] {
            Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
        messagesByAccount = keyed(snap.messagesByAccount)
        inboxPath = keyed(snap.inboxPath)
        foldersByAccount = keyed(snap.foldersByAccount)
        loadedFolders = Set(snap.loadedFolders)
        let total = messagesByAccount.values.reduce(0) { $0 + $1.count }
        logInfo("Cache: restored \(total) messages across \(messagesByAccount.count) account(s)", category: "cache")
    }

    /// Debounced background save so rapid changes coalesce into one write.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    private func persistNow() {
        func stringed<V>(_ dict: [UUID: V]) -> [String: V] {
            Dictionary(uniqueKeysWithValues: dict.map { ($0.key.uuidString, $0.value) })
        }
        cache.save(MessageCache.Snapshot(
            messagesByAccount: stringed(messagesByAccount),
            inboxPath: stringed(inboxPath),
            foldersByAccount: stringed(foldersByAccount),
            loadedFolders: Array(loadedFolders)
        ))
    }

    // MARK: periodic refresh (auto-receive on all folders)

    private func startPeriodicRefresh() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))   // every 3 min
                guard let self, !Task.isCancelled else { break }
                await self.refreshAllLoadedFolders()
            }
        }
    }

    /// Re-fetches every loaded folder (inbox is also IDLE-pushed) so folders
    /// keep downloading new mail, not just the inbox.
    func refreshAllLoadedFolders() async {
        for account in accounts where account.isEnabled {
            if Date() < warmerPauseUntil { continue }   // don't refresh while the user is active
            await sync(account)   // inbox
            let ip = inboxPath[account.id] ?? "INBOX"
            let openFolders = Array(Set((messagesByAccount[account.id] ?? []).map(\.folderPath)).subtracting([ip]))
            // Batched over a shared connection (one login for the lot).
            for (path, msgs) in await mailService.fetchFolders(account, paths: openFolders) {
                mergeMessages(account.id, folderPath: path, msgs)
            }
        }
    }

    // MARK: flagged (server-wide)

    /// Adds/updates messages without dropping others in the same folder.
    func upsertMessages(_ accountID: UUID, _ newMessages: [MailMessage]) {
        var byID = Dictionary((messagesByAccount[accountID] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in newMessages { byID[m.id] = m }
        messagesByAccount[accountID] = Array(byID.values)
        scheduleSave()
        updateDockBadge()
    }

    /// Searches every folder on every account for \Flagged and merges the
    /// results, so the Flagged view finds stars even in unopened folders.
    func refreshFlagged() {
        guard !isSearchingFlagged else { return }
        isSearchingFlagged = true
        Task {
            for account in accounts where account.isEnabled {
                if let found = try? await mailService.searchFlagged(account) {
                    upsertMessages(account.id, found)
                }
            }
            flaggedSearched = true
            isSearchingFlagged = false
        }
    }

    func ensureFlaggedLoaded() {
        guard !flaggedSearched else { return }
        refreshFlagged()
    }

    func applySettings(_ new: CourierSettings) {
        let clean = new.sanitized()
        settings = clean
        clean.save()
        Task {
            await mailService.updateSettings(clean)
            await ai.update(host: clean.aiUseLocal ? clean.localAIHost : clean.backendHost,
                            model: clean.aiModel,
                            sendToken: !clean.aiUseLocal)
        }
    }

    // Model list for the Settings picker.
    var availableModels: [String] = []

    func loadModels() async {
        let models = await ai.listModels()
        guard !models.isEmpty else { return }
        availableModels = models
        // Auto-heal: if the configured model isn't installed, pick the closest
        // match (prefer a "fable" model) so the copilot works out of the box.
        if !models.contains(settings.aiModel) {
            let match = models.first { $0.localizedCaseInsensitiveContains("fable") }
                ?? models.first { $0.localizedCaseInsensitiveContains("claude") }
                ?? models[0]
            var updated = settings
            updated.aiModel = match
            applySettings(updated)
            logInfo("AI: configured model not installed; auto-selected '\(match)'", category: "ai")
        }
    }

    // MARK: derived data

    /// Messages currently shown in the middle pane, per the sidebar selection.
    var displayedMessages: [MailMessage] {
        switch selection {
        case .unifiedInbox:
            // "All Inboxes" is a true all-mail view: inbox PLUS every non-system
            // folder across accounts, so mail filed into folders (and its unread)
            // still surfaces here and the filters can reach it. Individual account
            // selections stay inbox-only (the .folder case below).
            return unifiedMessages
        case .flagged:
            return flaggedMessages
        case .folder(let accountID, let path):
            return (messagesByAccount[accountID] ?? [])
                .filter { $0.folderPath == path }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    /// Whether a message belongs in the unified "All Inboxes" pool: everything you
    /// keep as mail (inbox, archive, custom folders) but NOT outgoing/system
    /// folders (Sent, Drafts, Trash, Junk) or Gmail's catch-all virtual folders
    /// (All Mail, Starred) which would duplicate everything.
    private func includedInUnified(_ m: MailMessage) -> Bool {
        let role = (foldersByAccount[m.accountID] ?? []).first { $0.path == m.folderPath }?.role
            ?? folderRole(for: m)
        switch role {
        case .sent, .drafts, .trash, .junk, .all, .flagged: return false
        default: return true
        }
    }

    /// The unified "All Inboxes" pool — every synced message across accounts and
    /// non-system folders, deduped by Message-ID so a mail that lives in a folder
    /// (or carries several Gmail labels) appears once.
    var unifiedMessages: [MailMessage] {
        var seen = Set<String>()
        var out: [MailMessage] = []
        for account in accounts {
            for m in (messagesByAccount[account.id] ?? []) where includedInUnified(m) {
                let key = m.messageID.map { $0.isEmpty ? m.id : $0 } ?? m.id
                if seen.insert(key).inserted { out.append(m) }
            }
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Unread across the unified all-mail pool (drives the "All Inboxes" badge).
    var unifiedUnreadCount: Int { unifiedMessages.filter(\.isUnread).count }

    func inboxMessages(for accountID: UUID) -> [MailMessage] {
        let ip = inboxPath[accountID] ?? "INBOX"
        return (messagesByAccount[accountID] ?? []).filter { $0.folderPath == ip }
    }

    /// All starred/flagged messages across every account and fetched folder.
    var flaggedMessages: [MailMessage] {
        accounts.flatMap { messagesByAccount[$0.id] ?? [] }
            .filter { $0.flags.contains(.flagged) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    var flaggedCount: Int { flaggedMessages.count }

    var selectedMessage: MailMessage? {
        displayedMessages.first { $0.id == selectedMessageID }
    }

    func account(for message: MailMessage) -> MailAccount? {
        accounts.first { $0.id == message.accountID }
    }

    /// Unread across all accounts' inboxes (the "All Inboxes" badge).
    var totalUnread: Int {
        accounts.reduce(0) { $0 + unread(for: $1.id) }
    }

    /// Unread in an account's inbox (the per-account badge).
    func unread(for accountID: UUID) -> Int {
        inboxMessages(for: accountID).filter(\.isUnread).count
    }

    /// Every selectable folder for an account (full list). Falls back to a
    /// synthetic INBOX until the real folder list has synced.
    func foldersToShow(for accountID: UUID) -> [MailFolder] {
        let folders = (foldersByAccount[accountID] ?? []).filter { $0.isSelectable }
        return folders.isEmpty ? [MailFolder(path: "INBOX", role: .inbox)] : folders
    }

    func folderKey(_ accountID: UUID, _ path: String) -> String { "\(accountID.uuidString):\(path)" }

    /// Selects an account-rail scope and moves the folder selection to match.
    /// NOTE: no `withAnimation` here — animating the scope change made the List
    /// crossfade rows and ghost/garble the row text ("All Inboxes" overlap).
    func selectScope(_ newScope: CourierScope) {
        scope = newScope
        selectedIDs = []
        switch newScope {
        case .all:
            selection = .unifiedInbox
        case .account(let id):
            let inbox = inboxPath[id] ?? foldersToShow(for: id).first { $0.role == .inbox }?.path ?? "INBOX"
            selection = .folder(accountID: id, path: inbox)
            expandedAccounts.insert(id)
        }
    }

    func toggleExpanded(_ id: UUID) {
        if expandedAccounts.contains(id) { expandedAccounts.remove(id) } else { expandedAccounts.insert(id) }
    }

    /// True when every account section is expanded (drives the expand/collapse-all button).
    var allExpanded: Bool {
        !accounts.isEmpty && accounts.allSatisfy { expandedAccounts.contains($0.id) }
    }

    func toggleExpandAll() {
        if allExpanded { expandedAccounts.removeAll() }
        else { expandedAccounts = Set(accounts.map(\.id)) }
    }

    /// Lazily fetches a folder's messages the first time it's opened.
    func ensureFolderLoaded(_ selection: SidebarSelection) {
        guard case .folder(let id, let path) = selection else { return }
        let key = folderKey(id, path)
        guard !loadedFolders.contains(key), let account = accounts.first(where: { $0.id == id }) else { return }
        loadedFolders.insert(key)  // optimistic — avoids duplicate concurrent loads
        Task {
            do {
                let messages = try await mailService.fetchFolder(account, folderPath: path)
                mergeMessages(id, folderPath: path, messages)
            } catch {
                loadedFolders.remove(key)
                banner = "Load \(path): \(error.localizedDescription)"
            }
        }
    }

    /// Replaces the messages for one folder within the flat per-account store.
    private func mergeMessages(_ accountID: UUID, folderPath: String, _ newMessages: [MailMessage]) {
        var list = messagesByAccount[accountID] ?? []
        list.removeAll { $0.folderPath == folderPath }
        list.append(contentsOf: newMessages)
        messagesByAccount[accountID] = list
        loadedFolders.insert(folderKey(accountID, folderPath))
        scheduleSave()
        updateDockBadge()
    }

    // MARK: sync

    func refresh() {
        Task {
            for account in accounts where account.isEnabled {
                await sync(account)
                await prefetchBodies(for: account)
                await syncAllFolders(account)
            }
        }
    }

    private func sync(_ account: MailAccount) async {
        isSyncing = true
        defer { isSyncing = false }
        logInfo("Sync starting for \(account.emailAddress) [\(account.provider.rawValue)]", category: "sync")
        do {
            let result = try await mailService.syncInbox(account)
            foldersByAccount[account.id] = result.folders
            let inbox = result.folders.first { $0.role == .inbox }?.path ?? "INBOX"
            inboxPath[account.id] = inbox
            mergeMessages(account.id, folderPath: inbox, result.messages)
            enforceBlocklist(account)
            logInfo("Sync done for \(account.emailAddress): \(result.folders.count) folders, \(result.messages.count) inbox messages", category: "sync")
        } catch {
            let base = error.localizedDescription
            var msg = "\(account.emailAddress): \(base)"
            if base.localizedCaseInsensitiveContains("authentication") {
                switch account.provider {
                case .icloud:
                    msg += " — iCloud needs an app-specific password (appleid.apple.com → Sign-In & Security → App-Specific Passwords), not your normal Apple ID password. Re-add the account with that."
                case .proton:
                    msg += " — use the password shown in Proton Mail Bridge, not your Proton login."
                default: break
                }
            }
            banner = msg
            logError("Sync FAILED — \(msg)", category: "sync")
        }
    }

    /// Proactively fetches every real folder's messages so the unified "All
    /// Inboxes" view and the filters (Unread, etc.) include folder mail without
    /// the user having to open each folder first. Skips the inbox (already
    /// synced), non-selectable containers, and the Gmail "All Mail" superset
    /// (which duplicates inbox/folder mail). Serialized per account by MailService.
    func syncAllFolders(_ account: MailAccount) async {
        let inbox = inboxPath[account.id] ?? "INBOX"
        let paths = (foldersByAccount[account.id] ?? []).filter {
            $0.isSelectable && $0.role != .all && $0.path != inbox
        }.map(\.path)
        guard !paths.isEmpty else { return }
        // Fetch folders in small groups over a SHARED connection (one login per
        // group instead of per folder) — far less churn/throttling. Releasing the
        // lock between groups lets interactive work jump ahead.
        for group in stride(from: 0, to: paths.count, by: 6).map({ Array(paths[$0..<min($0 + 6, paths.count)]) }) {
            if Task.isCancelled { return }
            while Date() < warmerPauseUntil {         // yield to the user
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(3))
            }
            for (path, messages) in await mailService.fetchFolders(account, paths: group) {
                mergeMessages(account.id, folderPath: path, messages)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        logInfo("Folder sync done for \(account.emailAddress): \(paths.count) folders", category: "sync")
    }

    /// Warms the body cache for the most recent inbox messages so opening them is
    /// instant (no "Loading…"). Uses BODY.PEEK (never marks read), skips already
    /// cached messages, and paces itself so it doesn't trip provider rate limits.
    func prefetchBodies(for account: MailAccount, limit: Int = 40) async {
        let items = inboxMessages(for: account.id)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(limit)
            .map { (folderPath: $0.folderPath, uid: $0.uid) }
        // One connection for the whole batch (no per-message login storm).
        let warmed = await mailService.ensureBodiesCached(account, items: Array(items))
        if warmed > 0 { logInfo("Prefetch: warmed \(warmed) bodies for \(account.emailAddress)", category: "cache") }
    }

    /// Continuous background cache warmer: while the app sits idle it works through
    /// EVERY message in EVERY folder and ensures each body is on disk, so opening
    /// anything is a local read — never a network fetch. Idempotent (already-cached
    /// messages are skipped instantly), paced only on real downloads, and it
    /// re-sweeps on a slow loop to pick up newly-arrived mail.
    /// Interactive IMAP ops call this so the background warmer backs off and
    /// yields its connections/locks to the user's action. The warmer only runs
    /// once the app has been idle for this window.
    @ObservationIgnored private var warmerPauseUntil = Date.distantPast
    func deferBackgroundWork() { warmerPauseUntil = Date().addingTimeInterval(45) }

    private func startCacheWarmer() {
        guard warmerTask == nil else { return }   // one warmer for the app's life
        // BACKGROUND priority so it always yields to the UI, the agent, and any
        // interactive mail op — the warmer must never make the app feel stuck.
        warmerTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.warmFullCache()
                try? await Task.sleep(for: .seconds(300))   // gentle: re-sweep every 5 min
            }
        }
    }

    func warmFullCache() async {
        var fetched = 0, total = 0
        for account in accounts where account.isEnabled {
            // Newest first so recent mail caches soonest; snapshot to avoid races.
            let items = (messagesByAccount[account.id] ?? [])
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                .map { (folderPath: $0.folderPath, uid: $0.uid) }
            total += items.count
            // Process in small chunks: each chunk reuses ONE connection (far fewer
            // logins → no provider throttling), and releasing the IMAP lock between
            // chunks lets interactive ops (open mail, empty spam, agent) run.
            for chunk in stride(from: 0, to: items.count, by: 10).map({ Array(items[$0..<min($0 + 10, items.count)]) }) {
                if Task.isCancelled { return }
                // Stand down while the user is active — never sit on the IMAP lock
                // an interactive action needs.
                while Date() < warmerPauseUntil {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(3))
                }
                let n = await mailService.ensureBodiesCached(account, items: chunk)
                fetched += n
                if n > 0 { try? await Task.sleep(for: .milliseconds(800)) }   // breathe between real downloads
                else { await Task.yield() }
            }
        }
        logInfo("Cache warmer: pass done — \(fetched) new bodies cached (\(total) messages known)", category: "cache")
    }

    private func startIdle(_ account: MailAccount) {
        let id = account.id
        Task {
            await mailService.startIdle(account) { [weak self] in
                await self?.onPushedNewMail(accountID: id)
            }
        }
    }

    private func onPushedNewMail(accountID: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        let before = Set(inboxMessages(for: accountID).map(\.id))
        await sync(account)
        let arrived = inboxMessages(for: accountID).contains { !before.contains($0.id) }
        if arrived { playNotificationSound() }
        await prefetchBodies(for: account, limit: 15)   // warm the freshly-arrived mail
    }

    /// Plays the user's chosen macOS system sound for a new-mail alert.
    func playNotificationSound() {
        let name = settings.notificationSound
        guard name != "None", !name.isEmpty,
              let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.play()
    }

    // MARK: message reading

    func selectMessage(_ message: MailMessage) {
        selectedIDs = [message.id]
        loadBodyForSelection()
    }

    /// Reacts to a change in `selectedIDs`: load the body when exactly one is
    /// selected; clear it for 0 or multiple (bulk) selections.
    func loadBodyForSelection() {
        if isPlayingVoicemail { stopVoicemail() }   // don't leave a voicemail playing after navigating away
        guard selectedIDs.count == 1, let id = selectedIDs.first,
              let message = displayedMessages.first(where: { $0.id == id }) else {
            openBody = nil
            isLoadingBody = false
            syncCopilotVisibility()   // nothing open → retract an auto-shown Copilot
            return
        }

        // Instant path: already fetched this message → show it immediately with no
        // network round-trip, and just fire off the mark-read in the background.
        if let cached = bodyCache[id] {
            openBody = cached
            isLoadingBody = false
            markReadIfNeeded(message)
            syncCopilotVisibility()   // body known → suggestions can use its content
            return
        }

        openBody = nil
        isLoadingBody = false
        syncCopilotVisibility()   // reveal on envelope signals (subject/sender) before the body arrives
        deferBackgroundWork()   // yield the account's IMAP lock to this open
        bodyLoadGen &+= 1
        let gen = bodyLoadGen
        // Only reveal the spinner if the fetch is actually slow (network). A disk
        // cache hit resolves well under this, so it never flashes "Loading".
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if gen == bodyLoadGen && openBody == nil { isLoadingBody = true }
        }
        Task {
            guard let account = account(for: message) else { isLoadingBody = false; return }
            do {
                let body = try await mailService.fetchBody(account, folderPath: message.folderPath, uid: message.uid)
                cacheBody(id, body)
                // The user may have moved on — only swap in if still current.
                if gen == bodyLoadGen {
                    openBody = body
                    isLoadingBody = false
                    syncCopilotVisibility()   // re-evaluate now that body text is available
                }
                markReadIfNeeded(message)
            } catch {
                if gen == bodyLoadGen { banner = error.localizedDescription; isLoadingBody = false }
            }
        }
    }
    @ObservationIgnored private var bodyLoadGen = 0

    /// Marks a message read on the server + locally (once), used by both the
    /// cached and freshly-fetched open paths.
    private func markReadIfNeeded(_ message: MailMessage) {
        guard message.isUnread, let account = account(for: message) else { return }
        markLocalRead(message)
        Task { try? await mailService.markRead(account, folderPath: message.folderPath, uid: message.uid, read: true) }
    }

    // MARK: multi-selection bulk actions

    var selectedMessages: [MailMessage] {
        displayedMessages.filter { selectedIDs.contains($0.id) }
    }

    // MARK: undo

    struct UndoAction: Identifiable { let id = UUID(); let summary: String; let reverse: () -> Void }
    var undoStack: [UndoAction] = []
    @ObservationIgnored private var isUndoing = false
    var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo(_ summary: String, reverse: @escaping () -> Void) {
        guard !isUndoing else { return }
        undoStack.append(UndoAction(summary: summary, reverse: reverse))
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
    }

    /// Reverses the most recent reversible action (mark read/unread, star, or a
    /// move — moved messages are relocated back by Message-ID).
    func undoLast() {
        guard let action = undoStack.popLast() else { return }
        isUndoing = true
        action.reverse()
        isUndoing = false
        banner = "Undid: \(action.summary)"
    }

    private func moveBackByMessageID(accountID: UUID, messageID: String?, from: String, to: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        guard let mid = messageID, !mid.isEmpty else { banner = "Can't undo move (message has no Message-ID)."; return }
        Task {
            do {
                try await mailService.moveByMessageID(account, messageID: mid, from: from, to: to)
                await sync(account)
            } catch {
                banner = "Undo move failed: \(error.localizedDescription)"
            }
        }
    }

    func bulkMarkRead(_ read: Bool) { selectedMessages.forEach { setRead($0, read) } }
    func bulkStar(_ starred: Bool) { selectedMessages.forEach { setFlagged($0, starred) } }
    /// True when every selected message is already starred (so the bulk button
    /// should offer to unstar).
    var allSelectedStarred: Bool {
        let msgs = selectedMessages
        return !msgs.isEmpty && msgs.allSatisfy { $0.flags.contains(.flagged) }
    }
    /// Stars the selection, or unstars it when everything selected is starred.
    func bulkToggleStar() { bulkStar(!allSelectedStarred) }
    func bulkArchive() { moveMessages(selectedMessages, toRole: .archive); selectedIDs = [] }
    func bulkTrash()   { moveMessages(selectedMessages, toRole: .trash); selectedIDs = [] }
    func bulkSpam()    { moveMessages(selectedMessages, toRole: .junk); selectedIDs = [] }

    private func markLocalRead(_ message: MailMessage) {
        guard var list = messagesByAccount[message.accountID],
              let idx = list.firstIndex(where: { $0.id == message.id }) else { return }
        list[idx].flags.insert(.seen)
        messagesByAccount[message.accountID] = list
    }

    // MARK: accounts

    /// Adds a password/app-password/bridge account and begins syncing it.
    func addPasswordAccount(provider: MailProvider, email: String, displayName: String,
                            password: String, imap: ServerEndpoint? = nil, smtp: ServerEndpoint? = nil) async {
        let id = UUID()
        let account = MailAccount(
            id: id,
            provider: provider,
            emailAddress: email,
            displayName: displayName.isEmpty ? email : displayName,
            imap: imap ?? ProviderCatalog.imap(for: provider),
            smtp: smtp ?? ProviderCatalog.smtp(for: provider),
            credentialRef: "account-\(id.uuidString)",
            sortIndex: accounts.count
        )
        Keychain.setString(password, account: account.credentialRef)
        await finalizeNewAccount(account)
    }

    /// Adds an OAuth account whose tokens were just obtained.
    func addOAuthAccount(provider: MailProvider, email: String, displayName: String, tokens: OAuthTokens) async {
        let id = UUID()
        let photo = provider == .gmail ? await fetchGooglePhoto(accessToken: tokens.accessToken) : nil
        let account = MailAccount(
            id: id,
            provider: provider,
            emailAddress: email,
            displayName: displayName.isEmpty ? email : displayName,
            imap: ProviderCatalog.imap(for: provider),
            smtp: ProviderCatalog.smtp(for: provider),
            credentialRef: "account-\(id.uuidString)",
            sortIndex: accounts.count,
            photoURL: photo
        )
        try? Keychain.setCodable(tokens, account: account.credentialRef)
        await finalizeNewAccount(account)
    }

    /// Reads the Google account's profile photo URL from the OpenID userinfo
    /// endpoint (requires the profile scope).
    private func fetchGooglePhoto(accessToken: String) async -> String? {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        struct UserInfo: Decodable { let picture: String? }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(UserInfo.self, from: data).picture
        } catch {
            return nil
        }
    }

    private func finalizeNewAccount(_ account: MailAccount) async {
        // Re-adding the same email+provider replaces the old entry (and its bad
        // credential) instead of creating a duplicate — the fix-my-password path.
        if let existing = accounts.first(where: {
            $0.emailAddress.caseInsensitiveCompare(account.emailAddress) == .orderedSame && $0.provider == account.provider
        }) {
            logInfo("Replacing existing account \(existing.emailAddress) [\(existing.provider.rawValue)]", category: "account")
            await mailService.stopIdle(existing.id)
            Keychain.delete(account: existing.credentialRef)
            accounts.removeAll { $0.id == existing.id }
            messagesByAccount[existing.id] = nil
            foldersByAccount[existing.id] = nil
        }
        logInfo("Adding account \(account.emailAddress) [\(account.provider.rawValue)] imap=\(account.imap.host):\(account.imap.port)", category: "account")
        accounts.append(account)
        do {
            try accountStore.save(accounts)
            logInfo("Account persisted to accounts.json (\(accounts.count) total)", category: "account")
        } catch {
            logError("Failed to persist accounts.json — \(error.localizedDescription)", category: "account")
        }
        isAddingAccount = false
        await sync(account)
        startIdle(account)
        Task { await syncAllFolders(account) }   // pull folders in the background
    }

    /// Triggers an interactive re-login / re-OAuth flow for an existing account.
    func reauthenticateAccount(_ account: MailAccount) {
        logInfo("Re-authenticating \(account.emailAddress) [\(account.provider.rawValue)]", category: "account")
        if account.provider.authKind == .oauth {
            guard let config = ProviderCatalog.oauth(for: account.provider,
                                                     clientID: account.provider == .gmail ? settings.googleClientID : settings.microsoftClientID,
                                                     clientSecret: Keychain.getString(account: "google-client-secret"),
                                                     tenant: settings.microsoftTenant) else {
                if account.provider == .outlook && settings.microsoftClientID.hasPrefix("GOCSPX-") {
                    banner = "Microsoft Client ID contains a Google secret ('GOCSPX-...'). Paste your Azure Application ID (GUID format) in Settings → Providers."
                } else {
                    banner = "Configure \(account.provider.rawValue.capitalized) Client ID in Settings → Providers first."
                }
                return
            }
            Task {
                do {
                    let auth = OAuthLoginController()
                    let tokens = try await auth.signIn(config: config)
                    try Keychain.setCodable(tokens, account: account.credentialRef)
                    banner = "Re-authenticated \(account.emailAddress) successfully."
                    await sync(account)
                    startIdle(account)
                } catch {
                    banner = "Re-authentication failed for \(account.emailAddress): \(error.localizedDescription)"
                }
            }
        } else {
            isAddingAccount = true
        }
    }

    func removeAccount(_ account: MailAccount) {
        logInfo("Removing account \(account.emailAddress) [\(account.provider.rawValue)]", category: "account")
        Task { await mailService.stopIdle(account.id) }
        Keychain.delete(account: account.credentialRef)
        accounts.removeAll { $0.id == account.id }
        messagesByAccount[account.id] = nil
        foldersByAccount[account.id] = nil
        inboxPath[account.id] = nil
        loadedFolders = loadedFolders.filter { !$0.hasPrefix("\(account.id.uuidString):") }
        try? accountStore.save(accounts)
        scheduleSave()
    }

    /// Updates an account's per-folder sync limit (nil/0 = all history) and
    /// re-fetches its already-loaded folders with the new limit.
    func setSyncLimit(_ account: MailAccount, _ limit: Int?) async {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].syncLimit = limit
        try? accountStore.save(accounts)
        loadedFolders = loadedFolders.filter { !$0.hasPrefix("\(account.id.uuidString):") }
        messagesByAccount[account.id] = nil
        await sync(accounts[idx])
    }

    /// Tests connect + auth with a password WITHOUT saving anything. Returns nil
    /// on success or a human-readable error. Used by the add/edit sheets.
    func testConnection(provider: MailProvider, email: String, password: String,
                        imap: ServerEndpoint? = nil) async -> String? {
        await mailService.testConnection(
            email: email,
            imap: imap ?? ProviderCatalog.imap(for: provider),
            authKind: provider.authKind,
            password: password
        )
    }

    /// Updates a password-based account's stored secret and/or display name,
    /// then re-syncs and restarts IDLE. The fix-my-password path for edits.
    func updateAccount(_ account: MailAccount, newPassword: String?, newDisplayName: String?) async {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if let newDisplayName, !newDisplayName.isEmpty {
            accounts[idx].displayName = newDisplayName
        }
        if let newPassword, !newPassword.isEmpty {
            Keychain.setString(newPassword, account: account.credentialRef)
            logInfo("Updated password for \(account.emailAddress)", category: "account")
        }
        try? accountStore.save(accounts)
        await mailService.stopIdle(account.id)
        await sync(accounts[idx])
        startIdle(accounts[idx])
    }

    // MARK: message actions

    /// Total count of unread inbox messages across all accounts (drives macOS Dock
    /// tile badge). Uses each account's real INBOX path — NOT the folderRole path
    /// heuristic, which misclassifies unread mail in custom folders / "All Mail"
    /// as inbox and inflated the badge (30 badge vs 0 in the inboxes).
    var totalUnreadCount: Int { totalUnread }

    /// Updates the macOS App Dock Tile badge with the current unread count.
    func updateDockBadge() {
        let count = totalUnreadCount
        Task { @MainActor in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    func mutate(_ message: MailMessage, _ transform: (inout MailMessage) -> Void) {
        guard var list = messagesByAccount[message.accountID],
              let idx = list.firstIndex(where: { $0.id == message.id }) else { return }
        transform(&list[idx])
        messagesByAccount[message.accountID] = list
        scheduleSave()
        updateDockBadge()
    }

    func removeLocal(_ message: MailMessage) {
        messagesByAccount[message.accountID]?.removeAll { $0.id == message.id }
        selectedIDs.remove(message.id)
        if selectedIDs.isEmpty { openBody = nil }
        scheduleSave()
        updateDockBadge()
    }

    /// When a single-selected message leaves the current view (moved/deleted),
    /// pick the next message to keep the reading pane populated: the following
    /// row in the visible list, falling back to the previous one if we removed
    /// the last. Returns nil unless `removed` is the sole current selection.
    /// Call this BEFORE removing, while `displayedMessages` still includes it.
    func selectionTarget(replacing removed: MailMessage) -> MailMessage? {
        guard selectedMessageID == removed.id else { return nil }
        let list = displayedMessages
        guard let idx = list.firstIndex(where: { $0.id == removed.id }) else { return nil }
        if idx + 1 < list.count { return list[idx + 1] }
        if idx > 0 { return list[idx - 1] }
        return nil
    }

    /// Selects the auto-advance target computed by `selectionTarget` and loads
    /// its body. No-op when `target` is nil (empty list / not a single move).
    func advanceSelection(to target: MailMessage?) {
        guard let target else { return }
        selectedIDs = [target.id]
        loadBodyForSelection()
    }

    /// Sets the flagged/starred state explicitly (agent-facing).
    func setFlagged(_ message: MailMessage, _ flagged: Bool) {
        guard let account = account(for: message) else { return }
        let wasFlagged = message.flags.contains(.flagged)
        pushUndo(flagged ? "star" : "unstar") { [weak self] in self?.setFlagged(message, wasFlagged) }
        mutate(message) { if flagged { $0.flags.insert(.flagged) } else { $0.flags.remove(.flagged) } }
        Task { try? await mailService.setFlagged(account, folderPath: message.folderPath, uid: message.uid, flagged: flagged) }
    }

    /// Moves a message to a role folder (agent-facing).
    func move(_ message: MailMessage, toRole role: FolderRole) {
        let fallback: String
        switch role {
        case .archive: fallback = "Archive"
        case .trash: fallback = "Trash"
        case .junk: fallback = "Junk"
        default: fallback = role.rawValue.capitalized
        }
        moveMessage(message, role: role, fallback: fallback)
    }

    // MARK: sender blocklist + security

    func isBlocked(_ address: String) -> Bool {
        settings.blockedSenders.contains(address.lowercased())
    }

    /// Blocks a sender: future mail from them auto-moves to Junk on sync, and
    /// their current messages are moved to Junk now.
    func blockSender(_ address: String) {
        let a = address.lowercased().trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        if !settings.blockedSenders.contains(a) {
            var s = settings; s.blockedSenders.append(a); applySettings(s)
            logInfo("Blocked sender \(a)", category: "account")
        }
        for account in accounts {
            let matching = (messagesByAccount[account.id] ?? [])
                .filter { $0.from.contains { $0.address.lowercased() == a } }
            for m in matching { move(m, toRole: .junk) }
        }
    }

    func unblockSender(_ address: String) {
        var s = settings
        s.blockedSenders.removeAll { $0 == address.lowercased() }
        applySettings(s)
    }

    /// Moves any inbox mail from blocked senders to Junk (called after sync).
    private func enforceBlocklist(_ account: MailAccount) {
        guard !settings.blockedSenders.isEmpty else { return }
        let blocked = Set(settings.blockedSenders)
        let ip = inboxPath[account.id] ?? "INBOX"
        let matching = (messagesByAccount[account.id] ?? []).filter { m in
            m.folderPath == ip && m.from.contains { blocked.contains($0.address.lowercased()) }
        }
        for m in matching { move(m, toRole: .junk) }
    }

    /// Runs the copilot as a security analyst on the currently-open email.
    func securityCheckOpenEmail() {
        guard let m = selectedMessage else {
            copilotTurns.append(CopilotTurn(role: .assistant, text: "Open an email first, then I'll run a security check on it."))
            return
        }
        isCopilotVisible = true
        let from = m.from.first?.address ?? ""
        runAgent("""
        Run a SECURITY CHECK on the email from \(from) with subject "\(m.subject)". \
        Use find_messages (from_contains the sender) to locate it, get_body to read it, then assess phishing / spoofing / scam / spam risk — look for mismatched or look-alike sender domains, urgent or threatening language, suspicious or mismatched links, and credential/payment requests. \
        If it is a clear threat: mark_spam it (move to Junk) and block_sender. If it's uncertain: star it for review and do NOT delete. \
        Report the specific risk signals and a clear verdict: **Safe**, **Suspicious**, or **Dangerous**.
        """)
    }

    /// The user asserts a message IS spam — quarantine it (move to Junk) and block the sender immediately.
    func reportSpam(_ message: MailMessage) {
        let from = message.from.first?.address ?? ""
        if !from.isEmpty {
            blockSender(from)
        }
        moveMessages([message], toRole: .junk)

        isCopilotVisible = true
        let domain = from.split(separator: "@").last.map(String.init) ?? from
        copilotTurns.append(CopilotTurn(role: .assistant, text: "Blocked \(from.isEmpty ? "sender" : from) and moved email to Junk."))
        
        runAgent("""
        The user reported email from \(from) with subject "\(message.subject)" as SPAM. \
        Sender \(from) is ALREADY blocked and this email has ALREADY been moved to Junk. \
        Call find_messages with from_contains "\(domain)" to check if any other messages from this sender/company remain in the inbox. \
        If any matching messages are found, call mark_spam on those handles to move them to Junk as well. \
        Finish by reporting how many additional messages were moved to Junk.
        """)
    }

    func reportSpamOpenEmail() {
        guard let m = selectedMessage else {
            isCopilotVisible = true
            copilotTurns.append(CopilotTurn(role: .assistant, text: "Open an email first, then tell me it's spam and I'll junk it + block the sender."))
            return
        }
        reportSpam(m)
    }

    /// Trashes every message from the open email's sender across all inboxes.
    /// This is a plain delete — it does NOT block the sender (blocking only
    /// happens via "Report as Spam" / "Block Sender").
    func deleteAllFromSenderOpenEmail() {
        guard let m = selectedMessage else {
            isCopilotVisible = true
            copilotTurns.append(CopilotTurn(role: .assistant, text: "Open an email first — then I'll delete every message from that sender."))
            return
        }
        isCopilotVisible = true
        let from = m.from.first?.address ?? ""
        runAgent("""
        The user wants to DELETE every email from \(from). \
        First call find_messages with from_contains "\(from)" to locate EVERY message from this sender across the inboxes — not just the open one. \
        Then trash ALL of those handles (move them to Trash — this is recoverable). \
        Do NOT block the sender and do NOT mark anything as spam. \
        Finish by telling the user how many messages you moved to Trash.
        """)
    }

    /// Permanently deletes every message in each account's Trash (or Junk)
    /// folder. This is a real expunge — it cannot be undone. Returns a summary.
    @discardableResult
    func performEmpty(role: FolderRole) async -> String {
        deferBackgroundWork()   // get the warmer out of the way
        let label = role == .junk ? "Junk" : "Trash"
        // Resolve each account's target folder up front (on the main actor).
        let targets: [(id: UUID, email: String, path: String)] = accounts
            .filter { $0.isEnabled }
            .compactMap { acc in resolveTargetFolder(acc, role: role, fallback: label).map { (acc.id, acc.emailAddress, $0) } }
        guard !targets.isEmpty else { return "None of your accounts have a \(label) folder." }
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let svc = mailService

        // Empty every account IN PARALLEL — one throttled/slow server no longer
        // blocks the rest, so the whole action finishes at the pace of the
        // slowest single account instead of the sum.
        let results: [(id: UUID, path: String, count: Int)] = await withTaskGroup(of: (UUID, String, Int).self) { group in
            for t in targets {
                guard let account = accountsByID[t.id] else { continue }
                group.addTask {
                    // Cap each account at 30s so a single throttled server (Gmail
                    // under connection pressure) can't hang the whole action.
                    let n = await withDeadline(seconds: 20, default: -1) {
                        (try? await svc.emptyTrash(account, trashPath: t.path)) ?? -1
                    }
                    return (t.id, t.path, n)
                }
            }
            var out: [(UUID, String, Int)] = []
            for await r in group { out.append((r.0, r.1, r.2)) }
            return out
        }

        var total = 0, failed = 0
        for r in results {
            if r.count >= 0 { total += r.count; messagesByAccount[r.id]?.removeAll { $0.folderPath == r.path } }
            else { failed += 1 }
        }
        scheduleSave(); updateDockBadge()
        var msg = "Permanently deleted \(total) message\(total == 1 ? "" : "s") from \(label) across \(targets.count) account\(targets.count == 1 ? "" : "s")."
        if failed > 0 { msg += " \(failed) account\(failed == 1 ? "" : "s") didn't respond in time — try again." }
        return msg
    }

    /// Runs a store-driven copilot action with a live "Thinking…" indicator and a
    /// result posted when it finishes. Cancellable via the Stop button.
    private func runCopilotAction(_ prompt: String, _ body: @escaping () async -> String) {
        isCopilotVisible = true
        copilotTurns.append(CopilotTurn(role: .user, text: prompt))
        copilotBusy = true
        copilotTask = Task {
            let summary = await body()
            if Task.isCancelled { return }
            copilotTurns.append(CopilotTurn(role: .assistant, text: summary))
            copilotBusy = false
            copilotTask = nil
        }
    }

    /// Copilot action: permanently empty every account's Trash.
    func emptyTrash() { runCopilotAction("Empty the Trash on all accounts.") { "🗑️ " + (await self.performEmpty(role: .trash)) } }

    /// Copilot action: permanently empty every account's Junk/Spam folder.
    func emptySpam() { runCopilotAction("Empty the Junk/Spam on all accounts.") { "🗑️ " + (await self.performEmpty(role: .junk)) } }

    /// Permanently empties a single folder for one account (the sidebar
    /// right-click "Empty Spam"/"Empty Trash"). Irreversible expunge.
    func emptyFolder(_ account: MailAccount, folder: MailFolder) {
        let label = folder.role == .junk ? "Junk" : (folder.role == .trash ? "Trash" : folder.displayName)
        Task {
            do {
                let n = try await mailService.emptyTrash(account, trashPath: folder.path)
                messagesByAccount[account.id]?.removeAll { $0.folderPath == folder.path }
                scheduleSave()
                updateDockBadge()
                banner = "Emptied \(label) — permanently deleted \(n) message\(n == 1 ? "" : "s")."
            } catch {
                banner = "Couldn't empty \(label): \(error.localizedDescription)"
            }
        }
    }

    func setRead(_ message: MailMessage, _ read: Bool) {
        guard let account = account(for: message) else { return }
        let wasRead = message.flags.contains(.seen)
        pushUndo(read ? "mark read" : "mark unread") { [weak self] in self?.setRead(message, wasRead) }
        mutate(message) { if read { $0.flags.insert(.seen) } else { $0.flags.remove(.seen) } }
        Task { try? await mailService.markRead(account, folderPath: message.folderPath, uid: message.uid, read: read) }
    }

    func toggleFlagged(_ message: MailMessage) {
        setFlagged(message, !message.flags.contains(.flagged))
    }

    func archive(_ message: MailMessage) { moveMessage(message, role: .archive, fallback: "Archive") }
    func trash(_ message: MailMessage)   { moveMessage(message, role: .trash, fallback: "Trash") }

    /// Finds an EXISTING destination folder for a role — by special-use role,
    /// then common name patterns, then a literal fallback only if it exists.
    /// Returns nil when the account genuinely has no such folder.
    private func resolveTargetFolder(_ account: MailAccount, role: FolderRole, fallback: String) -> String? {
        let folders = foldersByAccount[account.id] ?? []
        if let byRole = folders.first(where: { $0.role == role })?.path { return byRole }
        let patterns: [String]
        switch role {
        case .trash:   patterns = ["trash", "deleted", "bin"]
        case .junk:    patterns = ["junk", "spam"]
        case .archive: patterns = ["archive", "all mail"]
        default:       patterns = [role.rawValue.lowercased()]
        }
        if let byName = folders.first(where: { f in patterns.contains { f.path.lowercased().contains($0) } })?.path {
            return byName
        }
        return folders.contains(where: { $0.path == fallback }) ? fallback : nil
    }

    /// Returns the folder role for a message's folder path.
    func folderRole(for message: MailMessage) -> FolderRole {
        let path = message.folderPath.lowercased()
        if path.contains("junk") || path.contains("spam") { return .junk }
        if path.contains("trash") || path.contains("deleted") { return .trash }
        if path.contains("archive") { return .archive }
        if path.contains("sent") { return .sent }
        if path.contains("draft") { return .drafts }
        return .inbox
    }

    /// User-facing display name for a message's folder location.
    func folderDisplayName(for message: MailMessage) -> String {
        let role = folderRole(for: message)
        switch role {
        case .inbox: return "Inbox"
        case .junk: return "Junk"
        case .trash: return "Trash"
        case .archive: return "Archive"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        default: return "Inbox"
        }
    }

    func moveMessage(_ message: MailMessage, role: FolderRole, fallback: String) {
        guard let account = account(for: message) else { return }
        guard let target = resolveTargetFolder(account, role: role, fallback: fallback) else {
            banner = "\(account.displayName) has no \(role.rawValue) folder."
            logError("Move: no \(role.rawValue) folder for \(account.emailAddress)", category: "sync")
            return
        }
        guard target != message.folderPath else { return }
        let origin = message.folderPath
        pushUndo("move to \(role.rawValue)") { [weak self] in
            self?.moveBackByMessageID(accountID: account.id, messageID: message.messageID, from: target, to: origin)
        }

        // Auto-advance selection: if this was the open message, keep the reading
        // pane populated by moving to the next visible message. (NOTE: moving to
        // Junk does NOT block the sender — blocking only happens via explicit
        // "Block Sender" / "Report as Spam".)
        let advanceTo = selectionTarget(replacing: message)

        // Update folderPath locally and move message to target folder list so UI state updates instantly
        var movedMsg = message
        movedMsg.folderPath = target
        removeLocal(message)
        upsertMessages(account.id, [movedMsg])
        advanceSelection(to: advanceTo)

        logInfo("Move \(role.rawValue): uid \(message.uid) '\(origin)' → '\(target)' [\(account.emailAddress)]", category: "sync")
        Task {
            do {
                try await mailService.move(account, from: origin, uid: message.uid, to: target)
            } catch {
                logError("Move FAILED uid \(message.uid) → '\(target)': \(error.localizedDescription)", category: "sync")
                removeLocal(movedMsg)
                upsertMessages(account.id, [message])   // restore — it did NOT move
                banner = "Couldn't move to \(target): \(error.localizedDescription)"
            }
        }
    }

    /// Moves a message to an explicit folder path (used by the "Move to Folder"
    /// context submenu). Purely a move — never blocks the sender. Auto-advances
    /// the selection like the role-based move does.
    func moveToFolder(_ message: MailMessage, path: String) {
        guard let account = account(for: message), path != message.folderPath else { return }
        let origin = message.folderPath
        let folderName = (path as NSString).lastPathComponent
        pushUndo("move to \(folderName)") { [weak self] in
            self?.moveBackByMessageID(accountID: account.id, messageID: message.messageID, from: path, to: origin)
        }
        let advanceTo = selectionTarget(replacing: message)
        var movedMsg = message
        movedMsg.folderPath = path
        removeLocal(message)
        upsertMessages(account.id, [movedMsg])
        advanceSelection(to: advanceTo)

        logInfo("Move to folder: uid \(message.uid) '\(origin)' → '\(path)' [\(account.emailAddress)]", category: "sync")
        Task {
            do {
                try await mailService.move(account, from: origin, uid: message.uid, to: path)
            } catch {
                logError("Move FAILED uid \(message.uid) → '\(path)': \(error.localizedDescription)", category: "sync")
                removeLocal(movedMsg)
                upsertMessages(account.id, [message])   // restore — it did NOT move
                banner = "Couldn't move to \(folderName): \(error.localizedDescription)"
            }
        }
    }

    /// Batch version of moveToFolder for the multi-select "Move to Folder" action:
    /// moves every message to `path` over batched IMAP connections (one per
    /// account/origin), restoring on failure. Never blocks senders.
    func moveMessagesToFolder(_ messages: [MailMessage], path: String) {
        let toMove = messages.filter { $0.folderPath != path }
        guard !toMove.isEmpty else { return }
        let folderName = (path as NSString).lastPathComponent

        // Group by account + origin folder for batched moves.
        var grouped: [UUID: [String: [MailMessage]]] = [:]
        for m in toMove { grouped[m.accountID, default: [:]][m.folderPath, default: []].append(m) }

        // Instant local update.
        for m in toMove {
            var moved = m; moved.folderPath = path
            removeLocal(m)
            upsertMessages(m.accountID, [moved])
        }
        selectedIDs = []

        Task {
            for (accountID, byOrigin) in grouped {
                guard let account = accounts.first(where: { $0.id == accountID }) else { continue }
                for (origin, msgs) in byOrigin {
                    let uids = msgs.map(\.uid)
                    do {
                        try await mailService.moveBatch(account, from: origin, uids: uids, to: path)
                        logInfo("Batch move-to-folder \(uids.count) '\(origin)' → '\(path)' [\(account.emailAddress)]", category: "sync")
                    } catch {
                        logError("Batch move-to-folder FAILED \(uids.count) → '\(path)': \(error.localizedDescription)", category: "sync")
                        for m in msgs { var moved = m; moved.folderPath = path; removeLocal(moved) }
                        upsertMessages(accountID, msgs)   // restore originals
                        banner = "Couldn't move messages to \(folderName): \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Selectable folders a message can be moved into (excludes its current
    /// folder), for the "Move to Folder" submenu.
    func moveDestinations(for message: MailMessage) -> [MailFolder] {
        foldersToShow(for: message.accountID)
            .filter { $0.isSelectable && $0.path != message.folderPath }
            .sorted { $0.role.sortPriority < $1.role.sortPriority }
    }

    /// Batch-moves multiple messages over single IMAP connections per folder (prevents connection exhaustion).
    func moveMessages(_ messages: [MailMessage], toRole role: FolderRole) {
        guard !messages.isEmpty else { return }

        // Group by account and folder origin
        var grouped: [UUID: [String: [MailMessage]]] = [:]
        for m in messages {
            grouped[m.accountID, default: [:]][m.folderPath, default: []].append(m)
        }

        let fallback: String
        switch role {
        case .archive: fallback = "Archive"
        case .trash: fallback = "Trash"
        case .junk: fallback = "Junk"
        default: fallback = role.rawValue.capitalized
        }

        // Auto-advance selection only for a single-message move (bulk moves clear
        // the selection instead). Moving to Junk here does NOT block the sender.
        let advanceTo = messages.count == 1 ? selectionTarget(replacing: messages[0]) : nil

        // Apply local UI updates immediately so UI updates instantly
        for m in messages {
            if let acc = account(for: m), let target = resolveTargetFolder(acc, role: role, fallback: fallback) {
                var moved = m
                moved.folderPath = target
                removeLocal(m)
                upsertMessages(acc.id, [moved])
            } else {
                removeLocal(m)
            }
        }
        advanceSelection(to: advanceTo)

        // Execute batch moves on background Tasks (1 connection per origin folder per account)
        Task {
            for (accountID, folderMap) in grouped {
                guard let account = accounts.first(where: { $0.id == accountID }) else { continue }
                guard let targetFolder = resolveTargetFolder(account, role: role, fallback: fallback) else { continue }

                for (originFolder, msgList) in folderMap {
                    let uids = msgList.map(\.uid)
                    do {
                        try await mailService.moveBatch(account, from: originFolder, uids: uids, to: targetFolder)
                        logInfo("Batch move SUCCESS \(uids.count) msgs '\(originFolder)' → '\(targetFolder)' [\(account.emailAddress)]", category: "sync")
                    } catch {
                        logError("Batch move FAILED \(uids.count) msgs → '\(targetFolder)': \(error.localizedDescription)", category: "sync")
                        for m in msgList {
                            var restored = m
                            restored.folderPath = originFolder
                            removeLocal(m)
                        }
                        upsertMessages(accountID, msgList)
                        banner = "Couldn't move messages to \(targetFolder): \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - Auto-sort into matching folders

    /// User-triggered entry point (Copilot quick action): runs the auto-sort and
    /// reports the outcome in the Copilot conversation.
    func sortInboxesIntoFolders() {
        isCopilotVisible = true
        copilotTurns.append(CopilotTurn(role: .user, text: "Sort my inboxes into matching folders."))
        let summary = autoSortInboxesIntoFolders()
        copilotTurns.append(CopilotTurn(role: .assistant, text: summary))
    }

    /// Goes through every inbox and, when a message's sender company/service
    /// matches the NAME of an existing user folder in the same account, moves the
    /// message into that folder. Messages with no matching folder are left
    /// untouched (per design). Returns a human-readable summary of what moved.
    @discardableResult
    func autoSortInboxesIntoFolders() -> String {
        var movedTotal = 0
        var perFolder: [String: Int] = [:]

        for account in accounts {
            // User folders = selectable, non-role "other" folders (excludes INBOX,
            // Sent, Junk, Archive, etc. — only real user-created folders qualify).
            let userFolders = (foldersByAccount[account.id] ?? []).filter {
                $0.isSelectable && $0.role == .other && $0.displayName.count >= 3
                && !$0.displayName.lowercased().hasPrefix("[gmail]")
            }
            guard !userFolders.isEmpty else { continue }

            // origin folder -> target path -> [messages]
            var plan: [String: [String: [MailMessage]]] = [:]
            for msg in inboxMessages(for: account.id) {
                guard let target = matchingFolder(for: msg, in: userFolders),
                      target != msg.folderPath else { continue }
                plan[msg.folderPath, default: [:]][target, default: []].append(msg)
            }

            for (origin, targets) in plan {
                for (target, msgs) in targets {
                    for m in msgs {           // instant local UI update
                        var moved = m; moved.folderPath = target
                        removeLocal(m); upsertMessages(account.id, [moved])
                    }
                    let uids = msgs.map(\.uid)
                    let folderName = target.components(separatedBy: "/").last ?? target
                    perFolder[folderName, default: 0] += msgs.count
                    movedTotal += msgs.count
                    let acc = account
                    Task {
                        do {
                            try await mailService.moveBatch(acc, from: origin, uids: uids, to: target)
                            logInfo("Auto-sort moved \(uids.count) '\(origin)' → '\(target)' [\(acc.emailAddress)]", category: "sync")
                        } catch {
                            logError("Auto-sort move FAILED → '\(target)': \(error.localizedDescription)", category: "sync")
                            for m in msgs { removeLocal(m) }
                            upsertMessages(acc.id, msgs)   // restore — they did NOT move
                            banner = "Couldn't sort into \(folderName): \(error.localizedDescription)"
                        }
                    }
                }
            }
        }

        guard movedTotal > 0 else {
            return "Went through every inbox — no senders matched an existing folder, so nothing was moved."
        }
        let breakdown = perFolder.sorted { $0.value > $1.value }
            .map { "\($0.value) → \($0.key)" }.joined(separator: ", ")
        return "Sorted \(movedTotal) message\(movedTotal == 1 ? "" : "s") into matching folders (\(breakdown))."
    }

    /// Returns the path of the user folder whose name matches the message's
    /// sender company/service, or nil when nothing matches confidently. Domain
    /// second-level labels (github.com → "github") are matched first as they are
    /// the most reliable signal; sender display-name words are a fallback.
    private func matchingFolder(for message: MailMessage, in folders: [MailFolder]) -> String? {
        // Reliable tokens first: the domain second-level label of each sender.
        var domainTokens: [String] = []
        for addr in message.from.map(\.address) {
            guard let host = addr.split(separator: "@").last else { continue }
            let parts = host.lowercased().split(separator: ".")
            if parts.count >= 2 { domainTokens.append(String(parts[parts.count - 2])) }
        }
        // Fallback tokens: words from the sender's display name.
        var nameTokens: [String] = []
        for name in message.from.map(\.shortLabel) {
            for word in name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                if word.count >= 3 { nameTokens.append(String(word)) }
            }
        }
        let ordered = domainTokens.filter { $0.count >= 3 } + nameTokens
        guard !ordered.isEmpty else { return nil }

        for token in ordered {
            for folder in folders {
                let name = folder.displayName.lowercased()
                if name == token || name.contains(token) || token.contains(name) {
                    return folder.path
                }
            }
        }
        return nil
    }

    /// Drives the "New Folder" prompt (non-nil = prompt shown for this account).
    var folderPromptAccount: MailAccount?
    var newFolderName: String = ""

    func refreshFolders(_ account: MailAccount) async {
        if let folders = try? await mailService.listFolders(account) {
            foldersByAccount[account.id] = folders
            scheduleSave()
        }
    }

    func createFolder(named name: String, in account: MailAccount) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await mailService.createFolder(account, path: trimmed)
                await refreshFolders(account)
                banner = "Created folder “\(trimmed)”."
            } catch {
                banner = "Create folder failed: \(error.localizedDescription)"
            }
        }
    }

    /// True if a folder may be deleted (not a system/special-use folder).
    func canDeleteFolder(_ folder: MailFolder) -> Bool {
        ![.inbox, .sent, .drafts, .trash, .junk, .archive, .all].contains(folder.role)
    }

    func deleteFolder(_ folder: MailFolder, in account: MailAccount) {
        guard canDeleteFolder(folder) else {
            banner = "The \(folder.role.rawValue) folder can’t be deleted."
            return
        }
        Task {
            do {
                try await mailService.deleteFolder(account, path: folder.path)
                messagesByAccount[account.id]?.removeAll { $0.folderPath == folder.path }
                loadedFolders.remove(folderKey(account.id, folder.path))
                if selection == .folder(accountID: account.id, path: folder.path) { selection = .unifiedInbox }
                await refreshFolders(account)
                banner = "Deleted folder “\(folder.displayName)”."
            } catch {
                banner = "Delete folder failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: compose / reply / forward / send

    func beginCompose() { composeDraft = nil; isComposing = true }

    func reply(to message: MailMessage, all: Bool) {
        guard let account = account(for: message) else { return }
        var toList = message.from.map(\.address)
        var ccList: [String] = []
        if all {
            toList += message.to.map(\.address)
                .filter { $0.caseInsensitiveCompare(account.emailAddress) != .orderedSame }
            ccList = message.cc.map(\.address)
        }
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        composeDraft = ComposeDraft(accountID: account.id,
                                    to: dedupe(toList).joined(separator: ", "),
                                    cc: dedupe(ccList).joined(separator: ", "),
                                    subject: subject, body: "\n\n" + quotedReply(message),
                                    inReplyTo: message.messageID)
        isComposing = true
    }

    func forward(_ message: MailMessage) {
        guard let account = account(for: message) else { return }
        let subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
        composeDraft = ComposeDraft(accountID: account.id, subject: subject,
                                    body: "\n\n---------- Forwarded message ----------\n" + quotedReply(message))
        isComposing = true
    }

    private func dedupe(_ addrs: [String]) -> [String] {
        var seen = Set<String>(); return addrs.filter { seen.insert($0.lowercased()).inserted }
    }

    private func quotedReply(_ message: MailMessage) -> String {
        let who = message.from.first?.shortLabel ?? "someone"
        let when = message.date?.formatted(date: .abbreviated, time: .shortened) ?? ""
        // Only the currently-open message has a loaded body to quote.
        let body = (selectedMessageID == message.id ? openBody?.bestText : nil) ?? ""
        let quoted = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        return "On \(when), \(who) wrote:\n\(quoted)"
    }

    func send(_ message: OutgoingMessage, from account: MailAccount) async -> Bool {
        do {
            try await mailService.send(account, message: message)
            isComposing = false
            composeDraft = nil
            return true
        } catch {
            banner = "Send failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: copilot

    func runCopilot(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        copilotTurns.append(CopilotTurn(role: .user, text: trimmed))
        copilotBusy = true
        copilotTask = Task {
            let reply = await aiComplete(system: baseCopilotContext(), user: trimmed)
            if Task.isCancelled { return }
            copilotTurns.append(CopilotTurn(role: .assistant, text: reply))
            copilotBusy = false
            copilotTask = nil
        }
    }

    private func baseCopilotContext() -> String {
        var context = "You are the AI copilot inside Aether Courier, a macOS email app. "
        context += "The user has \(accounts.count) mail account(s). Answer in concise Markdown. "
        if let msg = selectedMessage {
            context += "\nThe currently open email is from \(msg.from.first?.shortLabel ?? "unknown") "
            context += "with subject \"\(msg.subject)\". "
            if let body = openBody { context += "Body:\n\(body.bestText.prefix(4000))" }
        }
        context += "\n\nUpcoming availability:\n\(calendar.availabilitySummary())"
        return context
    }

    private func aiComplete(system: String, user: String) async -> String {
        do { return try await ai.complete(system: system, messages: [.init(role: "user", content: user)]) }
        catch { return "⚠️ \(error.localizedDescription)" }
    }

    /// Full-mailbox triage: hand the agent a complete organize task. How much it
    /// actually does is governed by `settings.aiAutonomy` (injected into the agent
    /// prompt) — Cautious mostly proposes, Aggressive does it all.
    func organizeEverything() {
        isCopilotVisible = true
        runAgent("""
        Organize and triage ALL of my inboxes end to end. Work through each account in this order:
        1. Move obvious spam/junk to the Junk folder (do not block senders).
        2. Sort mail from a company or service into an EXISTING folder whose name matches it.
        3. Archive low-value, already-read notifications, newsletters and automated updates.
        4. Star anything genuinely important — from a real person, time-sensitive, or that needs a reply.
        5. Leave anything you're unsure about untouched. Do NOT permanently delete anything.
        When done, give a short summary grouped by what you did (sorted / archived / starred / spam) with counts.
        """)
    }

    /// Summarize the currently-open email.
    func summarizeOpenEmail() {
        guard selectedMessage != nil else {
            copilotTurns.append(CopilotTurn(role: .assistant, text: "Open an email first — then I'll summarize it."))
            return
        }
        isCopilotVisible = true
        runCopilot("Summarize the currently open email in 3 short bullets, then suggest a one-line reply.")
    }

    /// Unsubscribe from the currently-open email using the Copilot agent.
    func unsubscribeOpenEmail() {
        guard selectedMessage != nil else {
            copilotTurns.append(CopilotTurn(role: .assistant, text: "Open an email first — then I'll find its unsubscribe link."))
            return
        }
        isCopilotVisible = true
        runAgent("Unsubscribe from the currently open email. Locate its List-Unsubscribe header or unsubscribe link, open it in the browser, and report the result.")
    }

    /// Gather all unread across every inbox, summarize, and surface the important ones.
    func summarizeUnread() {
        isCopilotVisible = true
        let unread: [(MailAccount, MailMessage)] = accounts.flatMap { account in
            inboxMessages(for: account.id).filter(\.isUnread).map { (account, $0) }
        }
        guard !unread.isEmpty else {
            copilotTurns.append(CopilotTurn(role: .assistant, text: "You have **no unread messages** across your inboxes. 🎉"))
            return
        }
        let df = DateFormatter(); df.dateFormat = "MMM d, h:mm a"
        let lines = unread
            .sorted { ($0.1.date ?? .distantPast) > ($1.1.date ?? .distantPast) }
            .prefix(40)
            .map { account, m in
                "- [\(account.displayName)] From \(m.from.first?.shortLabel ?? "unknown"): \"\(m.subject.isEmpty ? "(no subject)" : m.subject)\"\(m.date.map { " · " + df.string(from: $0) } ?? "")"
            }
            .joined(separator: "\n")
        copilotTurns.append(CopilotTurn(role: .user, text: "Summarize my \(unread.count) unread messages"))
        copilotBusy = true
        let prompt = """
        Here are my \(unread.count) unread emails across all inboxes:
        \(lines)

        1. Give a concise summary grouped by sender or theme.
        2. Then an **Important** section highlighting anything time-sensitive, from a real person (not automated/marketing), or that likely needs a reply.
        """
        copilotTask = Task {
            let reply = await aiComplete(system: baseCopilotContext(), user: prompt)
            if Task.isCancelled { return }
            copilotTurns.append(CopilotTurn(role: .assistant, text: reply))
            copilotBusy = false
            copilotTask = nil
        }
    }

    /// Quick-action chips in the copilot header.
    func runQuickAction(_ action: CopilotQuickAction) {
        switch action {
        case .summarizeUnread: summarizeUnread()
        case .organizeAll: organizeEverything()
        case .summarizeEmail: summarizeOpenEmail()
        case .unsubscribeEmail: unsubscribeOpenEmail()
        case .securityCheck: securityCheckOpenEmail()
        case .reportSpam: reportSpamOpenEmail()
        case .deleteFromSender: deleteAllFromSenderOpenEmail()
        case .sortFolders: sortInboxesIntoFolders()
        case .emptyTrash: emptyTrash()
        case .emptySpam: emptySpam()
        case .compose: beginCompose()
        case .availability:
            copilotTurns.append(CopilotTurn(role: .assistant, text: calendar.availabilitySummary()))
        case .help: runCopilot("What can you help me do in Aether Courier?")
        }
    }
}

enum CopilotQuickAction: CaseIterable {
    case summarizeUnread, organizeAll, summarizeEmail, unsubscribeEmail, securityCheck, reportSpam, deleteFromSender, sortFolders, emptyTrash, emptySpam, compose, availability, help

    var title: String {
        switch self {
        case .summarizeUnread: return "Summarize unread & flag important"
        case .organizeAll: return "Organize & triage everything"
        case .summarizeEmail: return "Summarize this email"
        case .unsubscribeEmail: return "Unsubscribe from this email"
        case .securityCheck: return "Security check this email"
        case .reportSpam: return "Report this email as spam"
        case .deleteFromSender: return "Delete all from this sender"
        case .sortFolders: return "Sort inboxes into folders"
        case .emptyTrash: return "Empty trash (all accounts)"
        case .emptySpam: return "Empty spam (all accounts)"
        case .compose: return "Compose a new email"
        case .availability: return "Show my availability"
        case .help: return "What can you do?"
        }
    }
    var systemImage: String {
        switch self {
        case .summarizeUnread: return "tray.full"
        case .organizeAll: return "wand.and.rays"
        case .summarizeEmail: return "text.append"
        case .unsubscribeEmail: return "xmark.octagon"
        case .securityCheck: return "checkmark.shield"
        case .reportSpam: return "xmark.bin.fill"
        case .deleteFromSender: return "trash.slash"
        case .sortFolders: return "arrow.triangle.branch"
        case .emptyTrash: return "trash"
        case .emptySpam: return "xmark.bin"
        case .compose: return "square.and.pencil"
        case .availability: return "calendar"
        case .help: return "questionmark.circle"
        }
    }
}
