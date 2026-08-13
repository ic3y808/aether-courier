import Foundation

/// The completion status of a tagged IMAP command.
public struct IMAPTaggedResponse: Equatable, Sendable {
    public enum Status: String, Sendable { case ok = "OK", no = "NO", bad = "BAD" }
    public let tag: String
    public let status: Status
    public let text: String
}

/// A single untagged server event we act on.
public enum IMAPUntagged: Equatable, Sendable {
    case exists(Int)        // * 12 EXISTS  — mailbox now has N messages
    case expunge(Int)       // * 3 EXPUNGE  — message at seq N removed
    case recent(Int)        // * 1 RECENT
    case fetch(seq: Int, IMAPFetchResult)
    case list(MailFolder)
    case search([UInt32])
    case flags([String])
    case capability([String])
    case other(String)
}

/// The attributes we extract from a FETCH item.
public struct IMAPFetchResult: Equatable, Sendable {
    public var uid: UInt32?
    public var flags: MessageFlags = []
    public var flagAtoms: [String] = []
    public var size: Int?
    public var envelope: IMAPEnvelope?
    public var internalDate: Date?
    public var hasAttachments: Bool = false
    /// Raw body text captured from a BODY[]/BODY[HEADER]/BODY[TEXT] section.
    public var bodySection: String?
    public init() {}
}

/// Interpreted ENVELOPE fields.
public struct IMAPEnvelope: Equatable, Sendable {
    public var date: Date?
    public var subject: String = ""
    public var from: [MailAddress] = []
    public var to: [MailAddress] = []
    public var cc: [MailAddress] = []
    public var messageID: String?
}

/// Pure interpreters over `IMAPValue` and raw response lines. Everything here is
/// deterministic and side-effect free — the unit-test surface for the protocol.
public enum IMAPResponseParser {

    // MARK: Tagged status

    /// Parses `A001 OK [READ-WRITE] Completed` style lines. Returns nil for
    /// untagged (`*`) or continuation (`+`) lines.
    public static func parseTagged(_ line: String) -> IMAPTaggedResponse? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let tag = String(parts[0])
        guard tag != "*", tag != "+" else { return nil }
        guard let status = IMAPTaggedResponse.Status(rawValue: parts[1].uppercased()) else { return nil }
        let text = parts.count >= 3 ? String(parts[2]) : ""
        return IMAPTaggedResponse(tag: tag, status: status, text: text)
    }

    /// True for a continuation request (`+ ...`), used by IDLE / AUTHENTICATE.
    public static func isContinuation(_ line: String) -> Bool {
        line.hasPrefix("+")
    }

    // MARK: Untagged responses

    /// Parses an untagged response line (`* ...`). `bytes` should be the fully
    /// assembled line including any inlined literals.
    public static func parseUntagged(_ bytes: [UInt8]) -> IMAPUntagged? {
        let line = String(decoding: bytes, as: UTF8.self)
        guard line.hasPrefix("*") else { return nil }
        // Drop the "* " prefix.
        let rest = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
        let tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return nil }

        // Numeric-prefixed: "12 EXISTS", "3 EXPUNGE", "12 FETCH (...)".
        if let n = Int(tokens[0]), tokens.count >= 2 {
            let kind = tokens[1].uppercased()
            switch kind {
            case "EXISTS":  return .exists(n)
            case "EXPUNGE": return .expunge(n)
            case "RECENT":  return .recent(n)
            case "FETCH":
                if let result = parseFetchAttributes(bytes) {
                    return .fetch(seq: n, result)
                }
                return nil
            default:
                return .other(line)
            }
        }

        switch tokens[0].uppercased() {
        case "SEARCH":
            let uids = tokens.dropFirst().compactMap { UInt32($0) }
            return .search(Array(uids))
        case "FLAGS":
            if let list = firstParenList(bytes) {
                return .flags(list.compactMap { $0.stringValue })
            }
            return .flags([])
        case "CAPABILITY":
            return .capability(Array(tokens.dropFirst()))
        case "LIST", "LSUB", "XLIST":
            if let folder = parseListResponse(bytes) { return .list(folder) }
            return .other(line)
        default:
            return .other(line)
        }
    }

    // MARK: FETCH

    /// Extracts the `(...)` attribute list from a FETCH line and interprets it.
    public static func parseFetchAttributes(_ bytes: [UInt8]) -> IMAPFetchResult? {
        guard let attrs = firstParenList(bytes) else { return nil }
        var result = IMAPFetchResult()
        var idx = 0
        while idx < attrs.count {
            guard let key = attrs[idx].stringValue?.uppercased() else { idx += 1; continue }
            let value = idx + 1 < attrs.count ? attrs[idx + 1] : .nilValue
            switch key {
            case "UID":
                if let u = value.intValue { result.uid = UInt32(u) }
            case "RFC822.SIZE":
                result.size = value.intValue
            case "FLAGS":
                if let list = value.listValue {
                    let atoms = list.compactMap { $0.stringValue }
                    result.flagAtoms = atoms
                    result.flags = atoms.reduce(into: MessageFlags()) { acc, a in
                        if let f = MessageFlags.from(atom: a) { acc.insert(f) }
                    }
                }
            case "ENVELOPE":
                if let list = value.listValue {
                    result.envelope = parseEnvelope(list)
                }
            case "INTERNALDATE":
                if let s = value.stringValue { result.internalDate = parseInternalDate(s) }
            case "BODYSTRUCTURE", "BODY":
                if value.listValue != nil {
                    result.hasAttachments = value.contains(caseInsensitive: "attachment")
                } else if let s = value.stringValue {
                    result.bodySection = s
                }
            default:
                // BODY[...] section results arrive as key "BODY[HEADER]" etc.
                if key.hasPrefix("BODY["), let s = value.stringValue {
                    result.bodySection = s
                }
            }
            idx += 2
        }
        return result
    }

    // MARK: ENVELOPE

    /// ENVELOPE fields, in RFC 3501 order:
    /// date, subject, from, sender, reply-to, to, cc, bcc, in-reply-to, message-id
    public static func parseEnvelope(_ items: [IMAPValue]) -> IMAPEnvelope {
        var env = IMAPEnvelope()
        func addresses(_ v: IMAPValue?) -> [MailAddress] {
            guard let list = v?.listValue else { return [] }
            return list.compactMap { parseAddress($0) }
        }
        if items.count > 0, let d = items[0].stringValue { env.date = parseRFC2822Date(d) }
        if items.count > 1, let s = items[1].stringValue { env.subject = MIME.decodeWords(s) }
        if items.count > 2 { env.from = addresses(items[2]) }
        if items.count > 5 { env.to = addresses(items[5]) }
        if items.count > 6 { env.cc = addresses(items[6]) }
        if items.count > 9, let m = items[9].stringValue { env.messageID = m }
        return env
    }

    /// An address is `(name adl mailbox host)`.
    public static func parseAddress(_ v: IMAPValue) -> MailAddress? {
        guard let parts = v.listValue, parts.count >= 4 else { return nil }
        let name = parts[0].stringValue.map { MIME.decodeWords($0) }
        guard let mailbox = parts[2].stringValue, let host = parts[3].stringValue else { return nil }
        return MailAddress(name: name, address: "\(mailbox)@\(host)")
    }

    // MARK: LIST

    /// `* LIST (\HasNoChildren \Sent) "/" "Sent Messages"`
    public static func parseListResponse(_ bytes: [UInt8]) -> MailFolder? {
        var tok = IMAPTokenizer(bytes)
        guard let values = try? tok.parseAll() else { return nil }
        // values: ["*", "LIST", (flags), separator, name]
        guard let listIdx = values.firstIndex(where: { $0.stringValue?.uppercased() == "LIST" || $0.stringValue?.uppercased() == "LSUB" || $0.stringValue?.uppercased() == "XLIST" }) else { return nil }
        let rest = Array(values[(listIdx + 1)...])
        guard rest.count >= 3 else { return nil }
        let flags = rest[0].listValue?.compactMap { $0.stringValue } ?? []
        let separator = rest[1].stringValue ?? "/"
        guard let path = rest[2].stringValue else { return nil }

        var role: FolderRole = .other
        for f in flags { if let r = FolderRole.from(specialUse: f) { role = r; break } }
        if role == .other { role = FolderRole.from(name: path) }
        let selectable = !flags.contains { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame }
        return MailFolder(path: path, separator: separator.isEmpty ? "/" : separator,
                          role: role, isSelectable: selectable)
    }

    // MARK: helpers

    /// Returns the first top-level parenthesised list found in the bytes.
    static func firstParenList(_ bytes: [UInt8]) -> [IMAPValue]? {
        var tok = IMAPTokenizer(bytes)
        guard let values = try? tok.parseAll() else { return nil }
        for v in values { if let l = v.listValue { return l } }
        return nil
    }

    // MARK: dates

    private static let rfc2822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
    private static let rfc2822NoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        return f
    }()
    private static let internalDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    public static func parseRFC2822Date(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let d = rfc2822.date(from: trimmed) { return d }
        return rfc2822NoDay.date(from: trimmed)
    }

    public static func parseInternalDate(_ s: String) -> Date? {
        internalDateFmt.date(from: s.trimmingCharacters(in: .whitespaces))
    }
}
