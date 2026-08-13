import Foundation
import EmailKit

/// Ties EmailKit to configured accounts: resolves secrets from the Keychain,
/// opens authenticated IMAP/SMTP connections, and exposes the operations the UI
/// needs. On-demand operations use short-lived connections; IDLE uses a
/// dedicated long-lived one per account so new mail is pushed, never polled.
actor MailService {
    private var settings: CourierSettings
    /// Live IDLE tasks keyed by account id, so they can be cancelled on
    /// disable/removal.
    private var idleTasks: [UUID: Task<Void, Never>] = [:]

    init(settings: CourierSettings) {
        self.settings = settings
        try? FileManager.default.createDirectory(at: Self.bodyCacheDir, withIntermediateDirectories: true)
    }

    // MARK: persistent body cache (raw RFC822 bytes on disk)

    /// Message bodies never change, so we cache the raw message bytes on disk,
    /// keyed by account+folder+uid, and re-parse locally on read. This makes a
    /// message download exactly once — instant and offline-capable on reopen,
    /// even across app restarts. Raw bytes (not JSON) keep it compact.
    private static let bodyCacheDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Aether-Courier/bodies", isDirectory: true)
    }()

    /// Stable, filename-safe FNV-1a hash of the message key (Swift's Hasher is
    /// per-run randomized, so it can't be used for a persistent filename).
    private func bodyCacheURL(_ account: MailAccount, _ folderPath: String, _ uid: UInt32) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in "\(account.id.uuidString):\(folderPath):\(uid)".utf8 {
            hash = (hash ^ UInt64(b)) &* 0x100000001b3
        }
        return Self.bodyCacheDir.appendingPathComponent(String(format: "%016llx", hash)).appendingPathExtension("eml")
    }

    /// True if this message's body is already on disk (no network needed).
    func isBodyCached(_ account: MailAccount, folderPath: String, uid: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: bodyCacheURL(account, folderPath, uid).path)
    }

    /// Ensures the raw body is on disk, fetching once if missing. Does NOT parse
    /// or return it — used by the background cache warmer, which just needs the
    /// bytes persisted. Returns true iff a network fetch actually happened (so
    /// the caller can pace only real fetches, and blitz through already-cached).
    @discardableResult
    func ensureBodyCached(_ account: MailAccount, folderPath: String, uid: UInt32) async -> Bool {
        let url = bodyCacheURL(account, folderPath, uid)
        if FileManager.default.fileExists(atPath: url.path) { return false }
        do {
            let raw = try await withIMAP(account) { client -> [UInt8] in
                try await client.select(folderPath)
                return try await client.fetchRawMessage(uid: uid)
            }
            try? Data(raw).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Batch-caches many bodies over a SINGLE authenticated connection instead of
    /// one connect+auth per message — the fix for provider throttling under the
    /// cache warmer (Gmail/iCloud reject a flood of logins). Skips already-cached
    /// items, groups by folder to minimise SELECTs, and returns how many it
    /// actually downloaded. One connection is held for the whole batch, so keep
    /// batches modest (the warmer chunks its work).
    @discardableResult
    func ensureBodiesCached(_ account: MailAccount, items: [(folderPath: String, uid: UInt32)]) async -> Int {
        let fm = FileManager.default
        let missing = items.filter { !fm.fileExists(atPath: bodyCacheURL(account, $0.folderPath, $0.uid).path) }
                           .sorted { $0.folderPath < $1.folderPath }   // group folders together
        guard !missing.isEmpty else { return 0 }
        var fetched = 0
        do {
            try await withIMAP(account, priority: .background) { client in
                var currentFolder = ""
                for item in missing {
                    if Task.isCancelled { return }
                    if item.folderPath != currentFolder {
                        _ = try await client.select(item.folderPath)
                        currentFolder = item.folderPath
                    }
                    if let raw = try? await client.fetchRawMessage(uid: item.uid) {
                        try? Data(raw).write(to: self.bodyCacheURL(account, item.folderPath, item.uid), options: .atomic)
                        fetched += 1
                    }
                }
            }
        } catch {
            logWarn("Batch cache: \(account.emailAddress) — \(error.localizedDescription)", category: "cache")
        }
        return fetched
    }

    /// Bounds disk usage: keep the newest `maxFiles` cached bodies, delete older.
    func pruneBodyCache(maxFiles: Int = 20000) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.bodyCacheDir,
                    includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]),
              files.count > maxFiles else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b   // newest first
        }
        for url in sorted.dropFirst(maxFiles) { try? fm.removeItem(at: url) }
        logInfo("Body cache pruned: \(files.count) → \(maxFiles) files", category: "cache")
    }

    func updateSettings(_ new: CourierSettings) { settings = new }

    /// Normalises a secret before it goes on the wire. iCloud app-specific
    /// passwords are 16 chars displayed as `xxxx-xxxx-xxxx-xxxx`; the hyphens
    /// and any spaces are display separators, NOT part of the secret, and iCloud
    /// rejects the login if they're sent. Stripping them is a no-op when the
    /// user didn't type any. Other providers only get whitespace trimmed.
    private func normalizedSecret(_ authKind: MailAuthKind, _ password: String) -> String {
        switch authKind {
        case .appPassword:
            return password.filter { !$0.isWhitespace && $0 != "-" }
        default:
            return password.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: connection

    /// Opens an authenticated IMAP connection for an account.
    /// Picks the transport by TLS posture: STARTTLS endpoints need the Secure
    /// Transport-backed socket (Network.framework can't upgrade in place);
    /// implicit-TLS/plaintext use the Network.framework transport.
    private func makeTransport(_ endpoint: ServerEndpoint) -> MailTransport {
        endpoint.security == .startTLS
            ? STARTTLSTransport(endpoint: endpoint)
            : NWConnectionTransport(endpoint: endpoint)
    }

    private func openIMAP(_ account: MailAccount) async throws -> IMAPClient {
        let ep = account.imap
        logInfo("IMAP: connecting \(account.emailAddress) → \(ep.host):\(ep.port) (\(ep.security)) auth=\(account.provider.authKind.rawValue)", category: "imap")
        let client = IMAPClient(transport: makeTransport(ep))
        do {
            try await client.connect()
            if ep.security == .startTLS {
                try await client.startTLS()
                logInfo("IMAP: STARTTLS upgrade OK (\(account.emailAddress))", category: "imap")
            }
            logInfo("IMAP: connected + greeting OK (\(account.emailAddress))", category: "imap")
        } catch {
            logError("IMAP: connect failed \(ep.host):\(ep.port) — \(error.localizedDescription)", category: "imap")
            throw error
        }
        do {
            switch account.provider.authKind {
            case .oauth:
                let token = try await validAccessToken(for: account)
                try await client.authenticateXOAUTH2(user: account.emailAddress, accessToken: token)
            case .password, .appPassword, .bridge:
                guard let password = Keychain.getString(account: account.credentialRef) else {
                    logError("IMAP: no stored credential for \(account.emailAddress) (ref=\(account.credentialRef))", category: "imap")
                    throw MailServiceError.missingCredential
                }
                // SASL PLAIN (base64) — immune to the quoting/special-character
                // issues that make strict servers like iCloud reject the
                // quoted-string LOGIN command ("unmatch quote"). Supported by
                // iCloud and Proton Bridge; no CAPABILITY round-trip needed.
                logInfo("IMAP: authenticating via SASL PLAIN (\(account.emailAddress))", category: "imap")
                try await client.authenticatePlain(user: account.emailAddress,
                                                   password: normalizedSecret(account.provider.authKind, password))
            }
            logInfo("IMAP: authenticated \(account.emailAddress)", category: "imap")
        } catch {
            logError("IMAP: auth failed for \(account.emailAddress) — \(error.localizedDescription)", category: "imap")
            throw error
        }
        return client
    }

    private func openSMTP(_ account: MailAccount) async throws -> SMTPClient {
        let client = SMTPClient(transport: makeTransport(account.smtp))
        try await client.connect(useStartTLS: account.smtp.security == .startTLS)
        switch account.provider.authKind {
        case .oauth:
            let token = try await validAccessToken(for: account)
            try await client.authXOAUTH2(user: account.emailAddress, accessToken: token)
        case .password, .appPassword, .bridge:
            guard let password = Keychain.getString(account: account.credentialRef) else {
                throw MailServiceError.missingCredential
            }
            try await client.authLogin(user: account.emailAddress,
                                       password: normalizedSecret(account.provider.authKind, password))
        }
        return client
    }

    // MARK: connection test (used by the add-account sheet)

    /// Attempts connect + auth + a LIST with the supplied password, WITHOUT
    /// persisting anything. Returns nil on success, or a human error string.
    func testConnection(email: String, imap: ServerEndpoint, authKind: MailAuthKind, password: String) async -> String? {
        logInfo("TEST: \(email) → \(imap.host):\(imap.port) (\(imap.security))", category: "test")
        let secret = normalizedSecret(authKind, password)
        let transport = makeTransport(imap)
        let useStartTLS = imap.security == .startTLS
        do {
            try await withTimeout(seconds: 30) {
                let client = IMAPClient(transport: transport)
                try await client.connect()
                if useStartTLS { try await client.startTLS() }
                try await client.authenticatePlain(user: email, password: secret)
                let folders = try await client.listFolders()
                logInfo("TEST: OK — \(folders.count) folders visible for \(email)", category: "test")
                await client.disconnect()
            }
            return nil
        } catch {
            logError("TEST: failed for \(email) — \(error.localizedDescription)", category: "test")
            return error.localizedDescription
        }
    }

    // MARK: folder management

    func createFolder(_ account: MailAccount, path: String) async throws {
        let client = try await openIMAP(account)
        try await client.createMailbox(path)
        await client.disconnect()
        logInfo("Folder created '\(path)' (\(account.emailAddress))", category: "sync")
    }

    func deleteFolder(_ account: MailAccount, path: String) async throws {
        let client = try await openIMAP(account)
        try await client.deleteMailbox(path)
        await client.disconnect()
        logInfo("Folder deleted '\(path)' (\(account.emailAddress))", category: "sync")
    }

    /// Re-lists the account's folders (after create/delete).
    func listFolders(_ account: MailAccount) async throws -> [MailFolder] {
        let client = try await openIMAP(account)
        let folders = try await client.listFolders()
        await client.disconnect()
        return folders
    }

    // MARK: sync

    /// Lists folders and fetches the most recent `window` summaries from INBOX.
    func syncInbox(_ account: MailAccount) async throws -> (folders: [MailFolder], messages: [MailMessage]) {
        try await withTimeout(seconds: 45) {
            let client = try await self.openIMAP(account)
            let folders = try await client.listFolders()
            let inbox = folders.first(where: { $0.role == .inbox })?.path ?? "INBOX"
            logInfo("IMAP: \(folders.count) folders listed for \(account.emailAddress); inbox='\(inbox)'", category: "imap")
            let messages = try await self.fetchSummaries(client, account: account, folder: inbox)
            logInfo("IMAP: fetched \(messages.count) summaries from '\(inbox)' (\(account.emailAddress))", category: "imap")
            await client.disconnect()
            return (folders, messages)
        }
    }

    /// Fetches recent summaries from an arbitrary folder.
    /// Fetches several folders' summaries over ONE authenticated connection
    /// (instead of one connect+auth per folder) — big reduction in login churn,
    /// which is what throttles Gmail/iCloud. Background priority by default.
    func fetchFolders(_ account: MailAccount, paths: [String],
                      priority: OpPriority = .background) async -> [(path: String, messages: [MailMessage])] {
        guard !paths.isEmpty else { return [] }
        var out: [(String, [MailMessage])] = []
        do {
            try await withIMAP(account, priority: priority) { client in
                for path in paths {
                    if Task.isCancelled { return }
                    let msgs = (try? await self.fetchSummaries(client, account: account, folder: path)) ?? []
                    out.append((path, msgs))
                }
            }
        } catch {
            logWarn("fetchFolders \(account.emailAddress): \(error.localizedDescription)", category: "sync")
        }
        return out
    }

    func fetchFolder(_ account: MailAccount, folderPath: String,
                     priority: OpPriority = .interactive) async throws -> [MailMessage] {
        // Route through the per-account lock (was opening a bare concurrent
        // connection) so folder syncs don't pile extra logins onto throttling
        // providers, and so interactive work can jump ahead.
        try await withIMAP(account, priority: priority) { client in
            try await self.fetchSummaries(client, account: account, folder: folderPath)
        }
    }

    private func fetchSummaries(_ client: IMAPClient, account: MailAccount, folder: String) async throws -> [MailMessage] {
        try await client.select(folder)
        let uids = try await client.uidSearch("ALL")
        guard !uids.isEmpty else { return [] }
        // nil fetchCount = all history (default); otherwise the most recent N.
        let selected = account.fetchCount.map { Array(uids.suffix($0)) } ?? uids
        guard let lo = selected.first, let hi = selected.last else { return [] }
        let set = "\(lo):\(hi)"
        logInfo("IMAP: fetching \(selected.count) msgs from '\(folder)' (limit=\(account.fetchCount.map(String.init) ?? "all")) [\(account.emailAddress)]", category: "imap")
        var messages = try await client.fetchSummaries(uidSet: set)
        // Stamp the real account id and folder, newest first.
        for i in messages.indices {
            messages[i].accountID = account.id
            messages[i].folderPath = folder
        }
        return messages.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: per-account operation gate

    /// Short-lived IMAP operations are serialized per account so we never open a
    /// burst of concurrent connections. Providers cap concurrent IMAP sessions
    /// (iCloud especially) and reject the extras with "User is authenticated but
    /// not connected." — which is exactly what a rapid batch of deletes/moves
    /// triggered. The long-lived IDLE connection is separate and NOT gated here.
    private var opBusy: Set<UUID> = []
    private var opWaiters: [UUID: [(priority: Int, cont: CheckedContinuation<Void, Never>)]] = [:]

    /// Priorities for the per-account op lock. Interactive/AI work always jumps
    /// ahead of the background cache warmer when the lock frees.
    enum OpPriority: Int { case background = 0, interactive = 100 }

    private func acquireOpLock(_ id: UUID, priority: Int) async {
        if opBusy.contains(id) {
            await withCheckedContinuation { cont in
                opWaiters[id, default: []].append((priority, cont))
            }
        } else {
            opBusy.insert(id)
        }
    }

    private func releaseOpLock(_ id: UUID) {
        guard var waiters = opWaiters[id], !waiters.isEmpty else {
            opBusy.remove(id)
            return
        }
        // Serve the highest-priority waiter first (interactive before the warmer).
        var pick = 0
        for i in waiters.indices where waiters[i].priority > waiters[pick].priority { pick = i }
        let next = waiters.remove(at: pick)
        opWaiters[id] = waiters
        next.cont.resume()
    }

    private func isTransientConnection(_ error: Error) -> Bool {
        let m = error.localizedDescription.lowercased()
        return m.contains("not connected") || m.contains("authenticated but not")
            || (m.contains("connection") && m.contains("clos"))
    }

    /// Opens a short-lived connection, runs `body`, and disconnects — serialized
    /// per account, and retried once after a brief pause if the server rejects
    /// the connection transiently (the iCloud concurrency error above).
    private func withIMAP<T>(_ account: MailAccount,
                             priority: OpPriority = .interactive,
                             _ body: (IMAPClient) async throws -> T) async throws -> T {
        await acquireOpLock(account.id, priority: priority.rawValue)
        defer { releaseOpLock(account.id) }

        func attempt() async throws -> T {
            let client = try await openIMAP(account)
            do {
                let result = try await body(client)
                await client.disconnect()
                return result
            } catch {
                await client.disconnect()
                throw error
            }
        }

        do {
            return try await attempt()
        } catch {
            guard isTransientConnection(error) else { throw error }
            logWarn("IMAP: transient '\(error.localizedDescription)' for \(account.emailAddress) — retrying once", category: "imap")
            try? await Task.sleep(nanoseconds: 800_000_000)
            return try await attempt()
        }
    }

    /// Fetches and parses the full body for one message.
    func fetchBody(_ account: MailAccount, folderPath: String, uid: UInt32) async throws -> MailBody {
        let cacheURL = bodyCacheURL(account, folderPath, uid)
        // Disk hit → parse locally, no network. Refresh mtime for LRU pruning.
        if let data = try? Data(contentsOf: cacheURL), !data.isEmpty {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheURL.path)
            return MIMEMessageParser.parse([UInt8](data))
        }
        // Miss → fetch once (BODY.PEEK, no mark-read), persist, then parse.
        let raw = try await withIMAP(account) { client in
            try await client.select(folderPath)
            return try await client.fetchRawMessage(uid: uid)
        }
        try? Data(raw).write(to: cacheURL, options: .atomic)
        return MIMEMessageParser.parse(raw)
    }

    /// Searches EVERY folder on the account for \Flagged messages and returns
    /// their summaries — so the Flagged view finds stars anywhere, not just in
    /// folders already opened.
    func searchFlagged(_ account: MailAccount) async throws -> [MailMessage] {
        let client = try await openIMAP(account)
        defer { Task { await client.disconnect() } }
        let folders = try await client.listFolders()
        var out: [MailMessage] = []
        for folder in folders where folder.isSelectable {
            _ = try? await client.select(folder.path)
            let uids = (try? await client.uidSearch("FLAGGED")) ?? []
            guard !uids.isEmpty else { continue }
            let set = uids.map(String.init).joined(separator: ",")
            var msgs = (try? await client.fetchSummaries(uidSet: set)) ?? []
            for i in msgs.indices { msgs[i].accountID = account.id; msgs[i].folderPath = folder.path }
            out.append(contentsOf: msgs)
        }
        logInfo("Flagged search: \(out.count) flagged across \(folders.count) folders (\(account.emailAddress))", category: "sync")
        return out
    }

    /// Fetches a single top-level header (e.g. List-Unsubscribe) for a message.
    func fetchHeader(_ account: MailAccount, folderPath: String, uid: UInt32, name: String) async throws -> String? {
        let raw = try await withIMAP(account) { client in
            try await client.select(folderPath)
            return try await client.fetchRawMessage(uid: uid)
        }
        return MIMEMessageParser.headers(raw)[name.lowercased()]
    }

    func markRead(_ account: MailAccount, folderPath: String, uid: UInt32, read: Bool) async throws {
        try await withIMAP(account) { client in
            try await client.select(folderPath)
            try await client.store(uid: uid, flag: "\\Seen", add: read)
        }
    }

    func setFlagged(_ account: MailAccount, folderPath: String, uid: UInt32, flagged: Bool) async throws {
        try await withIMAP(account) { client in
            try await client.select(folderPath)
            try await client.store(uid: uid, flag: "\\Flagged", add: flagged)
        }
    }

    /// Moves a message identified by its Message-ID (used for undo, since the UID
    /// changes when a message moves folders).
    func moveByMessageID(_ account: MailAccount, messageID: String, from: String, to: String) async throws {
        try await withIMAP(account) { client in
            try await client.select(from)
            let uids = try await client.uidSearch("HEADER MESSAGE-ID \"\(messageID)\"")
            guard let uid = uids.first else { throw MailServiceError.notFound }
            try await client.move(uid: uid, to: to)
        }
    }

    /// Moves a message from its current folder to `target` (e.g. Archive/Trash).
    func move(_ account: MailAccount, from folderPath: String, uid: UInt32, to target: String) async throws {
        try await moveBatch(account, from: folderPath, uids: [uid], to: target)
    }

    /// Moves a set of messages from `folderPath` to `target` over a single IMAP connection.
    func moveBatch(_ account: MailAccount, from folderPath: String, uids: [UInt32], to target: String) async throws {
        guard !uids.isEmpty else { return }
        try await withIMAP(account) { client in
            _ = try await client.select(folderPath)
            try await client.move(uids: uids, to: target)
        }
    }

    /// Permanently deletes every message in `trashPath` (empty Trash). Returns
    /// the number of messages removed. Irreversible.
    @discardableResult
    func emptyTrash(_ account: MailAccount, trashPath: String) async throws -> Int {
        logInfo("Empty: '\(trashPath)' [\(account.emailAddress)] — selecting", category: "empty")
        return try await withIMAP(account) { client in
            let status = try await client.select(trashPath)
            let uids = try await client.uidSearch("ALL")
            logInfo("Empty: '\(trashPath)' selected (readOnly=\(status.readOnly)); \(uids.count) message(s) to expunge", category: "empty")
            guard !uids.isEmpty else { return 0 }
            do {
                try await client.expunge(uids: uids)
            } catch {
                logError("Empty: '\(trashPath)' expunge FAILED — \(error.localizedDescription)", category: "empty")
                throw error
            }
            logInfo("Empty: '\(trashPath)' expunged \(uids.count) message(s)", category: "empty")
            return uids.count
        }
    }

    // MARK: send

    func send(_ account: MailAccount, message: OutgoingMessage) async throws {
        let ep = account.smtp
        logInfo("SMTP: sending as \(account.emailAddress) → \(ep.host):\(ep.port) (\(ep.security)) auth=\(account.provider.authKind.rawValue), \(message.envelopeRecipients.count) recipient(s)", category: "smtp")
        do {
            let client = try await openSMTP(account)
            let raw = MIMEBuilder.build(message)
            try await client.send(from: account.emailAddress,
                                  recipients: message.envelopeRecipients,
                                  rawMessage: raw)
            await client.quit()
            logInfo("SMTP: sent OK (\(account.emailAddress))", category: "smtp")
        } catch {
            logError("SMTP: send FAILED for \(account.emailAddress) — \(error.localizedDescription)", category: "smtp")
            throw error
        }
    }

    // MARK: IDLE (push)

    /// Starts a long-lived IDLE connection on INBOX. `onNewMail` fires whenever
    /// the server reports new/expunged messages; the caller re-syncs.
    func startIdle(_ account: MailAccount, onNewMail: @escaping @Sendable () async -> Void) {
        stopIdle(account.id)
        let task = Task { [weak self] in
            guard let self else { return }
            var transientFailures = 0
            while !Task.isCancelled {
                do {
                    let client = try await self.openIMAP(account)
                    _ = try await client.select("INBOX")
                    // Populate capabilities — the greeting doesn't always include
                    // them, which previously made supportsIdle false and silently
                    // disabled push. All supported providers advertise IDLE.
                    _ = try? await client.capability()
                    guard await client.supportsIdle else {
                        logWarn("IDLE: \(account.emailAddress) server doesn't advertise IDLE; push disabled", category: "idle")
                        await client.disconnect()
                        return
                    }
                    transientFailures = 0
                    logInfo("IDLE: watching INBOX for \(account.emailAddress)", category: "idle")
                    try await client.idle { event in
                        switch event {
                        case .exists, .expunge, .recent:
                            Task { await onNewMail() }
                        default: break
                        }
                    }
                    await client.disconnect()
                } catch let e as IMAPClientError {
                    // An auth failure is permanent — reconnecting won't fix a bad
                    // credential, and hammering the server risks a rate-limit/lock.
                    // Stop the IDLE loop; the user must re-enter the password.
                    if case .authenticationFailed = e {
                        logError("IDLE: stopping for \(account.emailAddress) — auth rejected (fix the password, then re-add/refresh)", category: "idle")
                        return
                    }
                    transientFailures += 1
                    if transientFailures >= 6 {
                        logError("IDLE: giving up for \(account.emailAddress) after \(transientFailures) failures", category: "idle")
                        return
                    }
                    try? await Task.sleep(for: .seconds(min(15 * transientFailures, 120)))
                } catch let e as MailTransportError {
                    // STARTTLS-unsupported is permanent (awaiting the M2 transport)
                    // — never retry it. Other transport errors (e.g. Proton Bridge
                    // not running) may resolve, so back off and retry a few times.
                    if case .starttlsUnsupported = e {
                        logError("IDLE: stopping for \(account.emailAddress) — \(e.localizedDescription)", category: "idle")
                        return
                    }
                    transientFailures += 1
                    if transientFailures >= 6 { return }
                    try? await Task.sleep(for: .seconds(min(15 * transientFailures, 120)))
                } catch {
                    transientFailures += 1
                    if transientFailures >= 6 { return }
                    try? await Task.sleep(for: .seconds(min(15 * transientFailures, 120)))
                }
            }
        }
        idleTasks[account.id] = task
    }

    func stopIdle(_ accountID: UUID) {
        idleTasks[accountID]?.cancel()
        idleTasks[accountID] = nil
    }

    func stopAllIdle() {
        for (_, task) in idleTasks { task.cancel() }
        idleTasks.removeAll()
    }

    // MARK: OAuth token lifecycle

    /// Returns a non-expired access token, refreshing via the provider token
    /// endpoint and re-persisting when necessary.
    private func validAccessToken(for account: MailAccount) async throws -> String {
        guard var tokens = Keychain.getCodable(OAuthTokens.self, account: account.credentialRef) else {
            logError("OAuth: missing stored tokens for \(account.emailAddress)", category: "oauth")
            throw MailServiceError.missingCredential
        }
        // Auto-renew if token is expired or within 5 minutes of expiring
        let needsRefresh = tokens.isExpired || (tokens.expiresAt != nil && tokens.expiresAt! <= Date().addingTimeInterval(300))
        if !needsRefresh {
            return tokens.accessToken
        }

        guard let refresh = tokens.refreshToken, !refresh.isEmpty,
              let config = oauthConfig(for: account.provider) else {
            logError("OAuth: token for \(account.emailAddress) expired but no refresh_token or OAuthConfig available. Re-OAuth required.", category: "oauth")
            throw MailServiceError.tokenRefreshFailed
        }

        logInfo("OAuth: auto-renewing access token for \(account.emailAddress)...", category: "oauth")
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(OAuthPKCE.refreshBody(config: config, refreshToken: refresh).utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyStr = String(decoding: data, as: UTF8.self)
                logError("OAuth: refresh HTTP \(status) failed for \(account.emailAddress): \(bodyStr)", category: "oauth")
                throw MailServiceError.tokenRefreshFailed
            }
            let refreshed = try JSONDecoder().decode(OAuthTokens.self, from: data)
            tokens.accessToken = refreshed.accessToken
            tokens.expiresAt = refreshed.expiresAt ?? Date().addingTimeInterval(3600)
            if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                tokens.refreshToken = newRefresh
            }
            try? Keychain.setCodable(tokens, account: account.credentialRef)
            logInfo("OAuth: token auto-renewed successfully for \(account.emailAddress)", category: "oauth")
            return tokens.accessToken
        } catch {
            logError("OAuth: refresh network error for \(account.emailAddress) — \(error.localizedDescription)", category: "oauth")
            throw MailServiceError.tokenRefreshFailed
        }
    }

    private func oauthConfig(for provider: MailProvider) -> OAuthConfig? {
        switch provider {
        case .gmail:   return ProviderCatalog.oauth(for: .gmail, clientID: settings.googleClientID,
                                                    clientSecret: Keychain.getString(account: "google-client-secret"))
        case .outlook: return ProviderCatalog.oauth(for: .outlook, clientID: settings.microsoftClientID,
                                                    tenant: settings.microsoftTenant)
        default:       return nil
        }
    }
}

enum MailServiceError: Error, LocalizedError {
    case missingCredential
    case tokenRefreshFailed
    case timedOut
    case notFound

    var errorDescription: String? {
        switch self {
        case .missingCredential: return "No stored credential was found for this account."
        case .tokenRefreshFailed: return "Refreshing the OAuth access token failed. Sign in again."
        case .timedOut: return "The mail server did not respond in time (it may be throttling or offline)."
        case .notFound: return "The message could not be found in the source folder."
        }
    }
}

/// Runs `operation`, failing with `MailServiceError.timedOut` if it exceeds
/// `seconds`. Guards every on-demand mail op so a stalled/throttling server can
/// never wedge a sync indefinitely (IDLE is intentionally NOT wrapped — it
/// waits for pushes with no data for long periods by design).
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MailServiceError.timedOut
        }
        guard let result = try await group.next() else { throw MailServiceError.timedOut }
        group.cancelAll()
        return result
    }
}
