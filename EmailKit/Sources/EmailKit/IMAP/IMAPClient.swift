import Foundation

/// Status of a selected mailbox, from the SELECT/EXAMINE untagged responses.
public struct MailboxStatus: Equatable, Sendable {
    public var path: String
    public var exists: Int = 0
    public var recent: Int = 0
    public var uidValidity: UInt32?
    public var uidNext: UInt32?
    public var flags: [String] = []
    public var readOnly: Bool = false
}

public enum IMAPClientError: Error, LocalizedError {
    case greetingFailed(String)
    case commandFailed(command: String, status: String, text: String)
    case notSelected
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .greetingFailed(let s): return "IMAP greeting failed: \(s)"
        case .commandFailed(let c, let s, let t): return "IMAP \(c) \(s): \(t)"
        case .notSelected: return "No mailbox is selected."
        case .authenticationFailed(let s): return "IMAP authentication failed: \(s)"
        }
    }
}

/// A high-level IMAP client driving a `MailTransport`. One instance owns one
/// connection; the sync engine keeps a dedicated instance per account for its
/// IDLE connection and reuses another for on-demand fetches.
public actor IMAPClient {
    private let transport: MailTransport
    private let reader: LineReader
    private var tagCounter = 0
    private var capabilities: Set<String> = []
    public private(set) var selected: MailboxStatus?

    public init(transport: MailTransport) {
        self.transport = transport
        self.reader = LineReader(transport: transport)
    }

    // MARK: connection lifecycle

    /// Connects the transport and consumes the server greeting.
    public func connect() async throws {
        try await transport.connect()
        let greeting = try await readAssembledLine()
        let line = String(decoding: greeting, as: UTF8.self)
        guard line.contains("OK") || line.contains("PREAUTH") else {
            throw IMAPClientError.greetingFailed(line)
        }
        if case .capability(let caps)? = IMAPResponseParser.parseUntagged(greeting) {
            capabilities = Set(caps.map { $0.uppercased() })
        }
    }

    public func disconnect() async {
        _ = try? await execute("LOGOUT")
        await transport.close()
    }

    /// Issues `STARTTLS` and upgrades the transport to TLS in place. Call after
    /// `connect()` (which reads the plaintext greeting) and before authenticating,
    /// on `.startTLS` endpoints (e.g. Proton Mail Bridge).
    public func startTLS() async throws {
        let tagged = try await execute("STARTTLS")
        guard tagged.status == .ok else {
            throw IMAPClientError.commandFailed(command: "STARTTLS", status: tagged.status.rawValue, text: tagged.text)
        }
        try await transport.startTLS()
        // Capabilities can change post-TLS; callers that care re-query.
        capabilities.removeAll()
    }

    // MARK: authentication

    public func capability() async throws -> [String] {
        var caps: [String] = []
        _ = try await execute("CAPABILITY") { bytes in
            if case .capability(let c)? = IMAPResponseParser.parseUntagged(bytes) { caps = c }
        }
        capabilities = Set(caps.map { $0.uppercased() })
        return caps
    }

    public func login(user: String, password: String) async throws {
        let tagged = try await execute("LOGIN \(quoted(user)) \(quoted(password))")
        guard tagged.status == .ok else {
            throw IMAPClientError.authenticationFailed(tagged.text)
        }
    }

    /// SASL PLAIN authentication (RFC 4616). Credentials are base64-encoded, so
    /// this is immune to the quoting/special-character pitfalls of the `LOGIN`
    /// command — the correct path for strict servers like iCloud (which rejects
    /// quoted-string LOGIN with "unmatch quote"). Uses the two-step continuation
    /// flow so it works with or without SASL-IR.
    public func authenticatePlain(user: String, password: String) async throws {
        let tag = nextTag()
        try await transport.send("\(tag) AUTHENTICATE PLAIN\r\n")
        while true {
            let bytes = try await readAssembledLine()
            let line = String(decoding: bytes, as: UTF8.self)
            if IMAPResponseParser.isContinuation(line) {
                // authzid (empty) NUL authcid NUL passwd, base64-encoded.
                let raw = "\u{00}\(user)\u{00}\(password)"
                let ir = Data(raw.utf8).base64EncodedString()
                try await transport.send("\(ir)\r\n")
                continue
            }
            if let tagged = IMAPResponseParser.parseTagged(line), tagged.tag == tag {
                guard tagged.status == .ok else {
                    throw IMAPClientError.authenticationFailed(tagged.text)
                }
                return
            }
        }
    }

    /// SASL XOAUTH2 with the initial client response sent inline (SASL-IR).
    public func authenticateXOAUTH2(user: String, accessToken: String) async throws {
        let ir = OAuthPKCE.xoauth2String(user: user, accessToken: accessToken)
        let tag = nextTag()
        try await transport.send("\(tag) AUTHENTICATE XOAUTH2 \(ir)\r\n")
        while true {
            let bytes = try await readAssembledLine()
            let line = String(decoding: bytes, as: UTF8.self)
            if IMAPResponseParser.isContinuation(line) {
                // Server returned a base64 error challenge; acknowledge with an
                // empty line so it emits the tagged NO with detail.
                try await transport.send("\r\n")
                continue
            }
            if let tagged = IMAPResponseParser.parseTagged(line), tagged.tag == tag {
                guard tagged.status == .ok else {
                    throw IMAPClientError.authenticationFailed(tagged.text)
                }
                return
            }
        }
    }

    // MARK: mailboxes

    /// Lists all folders (`LIST "" "*"`), enriched with special-use roles.
    public func listFolders() async throws -> [MailFolder] {
        var folders: [MailFolder] = []
        _ = try await execute("LIST \"\" \"*\"") { bytes in
            if case .list(let folder)? = IMAPResponseParser.parseUntagged(bytes) {
                folders.append(folder)
            }
        }
        return folders.sorted {
            $0.role.sortPriority != $1.role.sortPriority
                ? $0.role.sortPriority < $1.role.sortPriority
                : $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    /// Selects a mailbox for read/write and returns its status.
    @discardableResult
    public func select(_ path: String) async throws -> MailboxStatus {
        var status = MailboxStatus(path: path)
        let tagged = try await execute("SELECT \(quoted(path))") { bytes in
            Self.applyMailboxUntagged(bytes, into: &status)
        }
        guard tagged.status == .ok else {
            throw IMAPClientError.commandFailed(command: "SELECT", status: tagged.status.rawValue, text: tagged.text)
        }
        status.readOnly = tagged.text.uppercased().contains("READ-ONLY")
        selected = status
        return status
    }

    /// UID SEARCH — returns matching UIDs. `criteria` defaults to ALL.
    public func uidSearch(_ criteria: String = "ALL") async throws -> [UInt32] {
        var uids: [UInt32] = []
        _ = try await execute("UID SEARCH \(criteria)") { bytes in
            if case .search(let found)? = IMAPResponseParser.parseUntagged(bytes) { uids = found }
        }
        return uids
    }

    /// Fetches envelope-level summaries for a UID set (e.g. "1:*", "10,12,15").
    public func fetchSummaries(uidSet: String) async throws -> [MailMessage] {
        guard let folder = selected?.path else { throw IMAPClientError.notSelected }
        var results: [(seq: Int, IMAPFetchResult)] = []
        _ = try await execute("UID FETCH \(uidSet) (UID FLAGS RFC822.SIZE INTERNALDATE ENVELOPE BODYSTRUCTURE)") { bytes in
            if case .fetch(let seq, let r)? = IMAPResponseParser.parseUntagged(bytes) {
                results.append((seq, r))
            }
        }
        return results.compactMap { Self.makeMessage(from: $0.1, folderPath: folder) }
    }

    /// Fetches the full raw RFC822 body for one UID (BODY.PEEK[] leaves \Seen
    /// untouched — marking read is an explicit user action).
    public func fetchRawMessage(uid: UInt32) async throws -> [UInt8] {
        var body: [UInt8] = []
        _ = try await execute("UID FETCH \(uid) (BODY.PEEK[])") { bytes in
            if case .fetch(_, let r)? = IMAPResponseParser.parseUntagged(bytes), let s = r.bodySection {
                body = Array(s.utf8)
            }
        }
        return body
    }

    /// Adds or removes a flag on a UID (e.g. mark read = add \Seen).
    public func store(uid: UInt32, flag: String, add: Bool) async throws {
        let op = add ? "+FLAGS" : "-FLAGS"
        let tagged = try await execute("UID STORE \(uid) \(op) (\(flag))")
        guard tagged.status == .ok else {
            throw IMAPClientError.commandFailed(command: "STORE", status: tagged.status.rawValue, text: tagged.text)
        }
    }

    /// Permanently removes the given UIDs from the currently-selected mailbox
    /// (marks them \Deleted then EXPUNGEs). Used to empty Trash. Irreversible.
    public func expunge(uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let uidSet = uids.map(String.init).joined(separator: ",")
        let tagged = try await execute("UID STORE \(uidSet) +FLAGS (\\Deleted)")
        guard tagged.status == .ok else {
            throw IMAPClientError.commandFailed(command: "STORE", status: tagged.status.rawValue, text: tagged.text)
        }
        // UID EXPUNGE (RFC 4315) removes only the flagged UIDs; fall back to a
        // plain EXPUNGE on servers without UIDPLUS.
        let byUid = try await execute("UID EXPUNGE \(uidSet)")
        if byUid.status != .ok { _ = try await execute("EXPUNGE") }
    }

    /// Creates a new mailbox/folder.
    public func createMailbox(_ path: String) async throws {
        let tagged = try await execute("CREATE \(quoted(path))")
        guard tagged.status == .ok else {
            throw IMAPClientError.commandFailed(command: "CREATE", status: tagged.status.rawValue, text: tagged.text)
        }
    }

    /// Deletes a mailbox/folder.
    public func deleteMailbox(_ path: String) async throws {
        let tagged = try await execute("DELETE \(quoted(path))")
        guard tagged.status == .ok else {
            throw IMAPClientError.commandFailed(command: "DELETE", status: tagged.status.rawValue, text: tagged.text)
        }
    }

    /// Moves a message to another mailbox. Prefers UID MOVE (RFC 6851) and
    /// falls back to COPY + \Deleted + EXPUNGE on servers without MOVE.
    public func move(uid: UInt32, to folder: String) async throws {
        try await move(uids: [uid], to: folder)
    }

    /// Moves a set of messages by UID to another mailbox in a single IMAP command.
    public func move(uids: [UInt32], to folder: String) async throws {
        guard !uids.isEmpty else { return }
        let uidSet = uids.map(String.init).joined(separator: ",")
        let moved = try await execute("UID MOVE \(uidSet) \(quoted(folder))")
        if moved.status == .ok { return }
        // Fallback for servers lacking the MOVE extension.
        let copy = try await execute("UID COPY \(uidSet) \(quoted(folder))")
        guard copy.status == .ok else {
            throw IMAPClientError.commandFailed(command: "COPY", status: copy.status.rawValue, text: copy.text)
        }
        for uid in uids {
            try await store(uid: uid, flag: "\\Deleted", add: true)
        }
        _ = try await execute("UID EXPUNGE \(uidSet)")
    }

    // MARK: IDLE (push)

    /// Enters IDLE and forwards untagged events until the task is cancelled.
    /// On cancellation a `DONE` is sent so the server ends IDLE cleanly. The
    /// caller reacts to `.exists`/`.expunge` by re-fetching new UIDs.
    public func idle(onEvent: @escaping @Sendable (IMAPUntagged) -> Void) async throws {
        let tag = nextTag()
        try await transport.send("\(tag) IDLE\r\n")
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                let bytes = try await readAssembledLine()
                let line = String(decoding: bytes, as: UTF8.self)
                if IMAPResponseParser.isContinuation(line) { continue }  // "+ idling"
                if let tagged = IMAPResponseParser.parseTagged(line), tagged.tag == tag { return }
                if let event = IMAPResponseParser.parseUntagged(bytes) { onEvent(event) }
            }
        } onCancel: {
            Task { await self.sendRaw("DONE\r\n") }
        }
    }

    public var supportsIdle: Bool { capabilities.contains("IDLE") }

    // MARK: command plumbing

    /// Runs a tagged command, routing untagged lines to `onUntagged`, and
    /// returns the tagged completion.
    @discardableResult
    private func execute(_ command: String,
                         onUntagged: (( [UInt8]) -> Void)? = nil) async throws -> IMAPTaggedResponse {
        let tag = nextTag()
        try await transport.send("\(tag) \(command)\r\n")
        while true {
            let bytes = try await readAssembledLine()
            let line = String(decoding: bytes, as: UTF8.self)
            if let tagged = IMAPResponseParser.parseTagged(line), tagged.tag == tag {
                return tagged
            }
            onUntagged?(bytes)
        }
    }

    private func sendRaw(_ s: String) async {
        try? await transport.send(s)
    }

    /// Reads one logical response, inlining IMAP literals so the tokenizer sees
    /// `{n}CRLF<bytes>` in a single byte buffer.
    private func readAssembledLine() async throws -> [UInt8] {
        var acc: [UInt8] = []
        while true {
            let line = try await reader.readLine()
            acc.append(contentsOf: Array(line.utf8))
            if let n = Self.trailingLiteralCount(line) {
                acc.append(0x0D); acc.append(0x0A)
                let lit = try await reader.readBytes(n)
                acc.append(contentsOf: lit)
                continue
            }
            return acc
        }
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "A%04d", tagCounter)
    }

    private func quoted(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    // MARK: static parse helpers

    /// A line ending in `{123}` (or `{123+}`) announces a following literal.
    static func trailingLiteralCount(_ line: String) -> Int? {
        guard line.hasSuffix("}") else { return nil }
        guard let open = line.lastIndex(of: "{") else { return nil }
        var inner = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
        if inner.hasSuffix("+") { inner.removeLast() }
        return Int(inner)
    }

    static func applyMailboxUntagged(_ bytes: [UInt8], into status: inout MailboxStatus) {
        guard let u = IMAPResponseParser.parseUntagged(bytes) else { return }
        switch u {
        case .exists(let n): status.exists = n
        case .recent(let n): status.recent = n
        case .flags(let f): status.flags = f
        case .other(let line):
            if let v = Self.bracketValue(line, key: "UIDVALIDITY") { status.uidValidity = UInt32(v) }
            if let v = Self.bracketValue(line, key: "UIDNEXT") { status.uidNext = UInt32(v) }
        default: break
        }
    }

    /// Extracts `NNN` from a response-code like `[UIDVALIDITY 123]`.
    static func bracketValue(_ line: String, key: String) -> String? {
        guard let r = line.range(of: "\(key) ", options: .caseInsensitive) else { return nil }
        let tail = line[r.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    static func makeMessage(from r: IMAPFetchResult, folderPath: String, accountID: UUID = UUID()) -> MailMessage? {
        guard let uid = r.uid else { return nil }
        let env = r.envelope
        return MailMessage(
            uid: uid,
            folderPath: folderPath,
            accountID: accountID,
            messageID: env?.messageID,
            subject: env?.subject ?? "",
            from: env?.from ?? [],
            to: env?.to ?? [],
            cc: env?.cc ?? [],
            date: env?.date ?? r.internalDate,
            flags: r.flags,
            snippet: "",
            hasAttachments: r.hasAttachments,
            sizeBytes: r.size
        )
    }
}
