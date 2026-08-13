import Foundation

/// An email address with an optional display name (`"Ada Lovelace <ada@x.io>"`).
public struct MailAddress: Codable, Sendable, Hashable, Identifiable {
    public var name: String?
    public var address: String

    public var id: String { address }

    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }

    /// RFC 5322 rendering for a header value.
    public var rfc5322: String {
        guard let name, !name.isEmpty else { return address }
        return "\(MIME.encodePhraseIfNeeded(name)) <\(address)>"
    }

    /// Short label for the UI (name if present, else the local/address part).
    public var shortLabel: String {
        if let name, !name.isEmpty { return name }
        return address
    }
}

/// IMAP system + custom flags on a message.
public struct MessageFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let seen     = MessageFlags(rawValue: 1 << 0)
    public static let answered = MessageFlags(rawValue: 1 << 1)
    public static let flagged  = MessageFlags(rawValue: 1 << 2)
    public static let deleted  = MessageFlags(rawValue: 1 << 3)
    public static let draft    = MessageFlags(rawValue: 1 << 4)
    public static let recent   = MessageFlags(rawValue: 1 << 5)

    /// Maps an IMAP flag atom (e.g. `\Seen`) to its bit, or nil for keywords.
    public static func from(atom: String) -> MessageFlags? {
        switch atom.lowercased() {
        case "\\seen":     return .seen
        case "\\answered": return .answered
        case "\\flagged":  return .flagged
        case "\\deleted":  return .deleted
        case "\\draft":    return .draft
        case "\\recent":   return .recent
        default:           return nil
        }
    }
}

/// A message envelope — the light-weight header summary shown in the list. The
/// full body is fetched lazily (`MailBody`) only when a message is opened.
public struct MailMessage: Codable, Sendable, Identifiable, Hashable {
    /// Stable identity within a folder: the IMAP UID.
    public var uid: UInt32
    public var folderPath: String
    public var accountID: UUID
    public var messageID: String?
    public var subject: String
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var date: Date?
    public var flags: MessageFlags
    /// First slice of the body text, for the list preview row.
    public var snippet: String
    public var hasAttachments: Bool
    /// Size in bytes as reported by RFC822.SIZE, when known.
    public var sizeBytes: Int?

    public var id: String { "\(accountID.uuidString):\(folderPath):\(uid)" }

    public init(
        uid: UInt32,
        folderPath: String,
        accountID: UUID,
        messageID: String? = nil,
        subject: String = "",
        from: [MailAddress] = [],
        to: [MailAddress] = [],
        cc: [MailAddress] = [],
        date: Date? = nil,
        flags: MessageFlags = [],
        snippet: String = "",
        hasAttachments: Bool = false,
        sizeBytes: Int? = nil
    ) {
        self.uid = uid
        self.folderPath = folderPath
        self.accountID = accountID
        self.messageID = messageID
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.flags = flags
        self.snippet = snippet
        self.hasAttachments = hasAttachments
        self.sizeBytes = sizeBytes
    }

    public var isUnread: Bool { !flags.contains(.seen) }
}

/// The fully-decoded body of a message, produced by the MIME parser.
public struct MailBody: Codable, Sendable, Hashable {
    public var plainText: String?
    public var html: String?
    public var attachments: [MailAttachment]

    public init(plainText: String? = nil, html: String? = nil, attachments: [MailAttachment] = []) {
        self.plainText = plainText
        self.html = html
        self.attachments = attachments
    }

    /// Best text for AI summarisation / previews: prefer plain, fall back to a
    /// crude HTML strip.
    public var bestText: String {
        if let plainText, !plainText.isEmpty { return plainText }
        if let html { return MIME.stripHTML(html) }
        return ""
    }
}

public struct MailAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var sizeBytes: Int
    /// Raw bytes when materialised; nil for a not-yet-downloaded part.
    public var data: Data?

    public init(id: UUID = UUID(), filename: String, mimeType: String, sizeBytes: Int, data: Data? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
    }
}
