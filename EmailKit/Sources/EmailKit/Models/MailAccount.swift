import Foundation

/// A configured mail account. This is the *persisted* description of how to
/// reach a mailbox — never the secret itself. Passwords and OAuth tokens live
/// in the Keychain (see the app-side `KeychainCredentialStore`); this struct
/// only carries the Keychain reference so account config can be stored as plain
/// JSON without leaking credentials.
public struct MailAccount: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var provider: MailProvider
    /// The full email address, also the IMAP/SMTP login username by default.
    public var emailAddress: String
    /// Display name used on the From header and in the sidebar.
    public var displayName: String
    /// Server coordinates (host/port/security), resolved from the catalog but
    /// overridable for `.custom` / self-hosted setups.
    public var imap: ServerEndpoint
    public var smtp: ServerEndpoint
    /// The Keychain account key under which this account's secret is stored.
    public var credentialRef: String
    /// User ordering in the sidebar.
    public var sortIndex: Int
    /// When false the account is configured but its connections are torn down.
    public var isEnabled: Bool
    /// Remote profile-photo URL (e.g. the Google account picture), when known.
    public var photoURL: String?
    /// How many recent messages to fetch per folder. nil or ≤0 means ALL
    /// history (the default). Configurable per account in the edit screen.
    public var syncLimit: Int?

    /// Effective count to fetch, or nil for "all history".
    public var fetchCount: Int? {
        guard let n = syncLimit, n > 0 else { return nil }
        return n
    }

    public init(
        id: UUID = UUID(),
        provider: MailProvider,
        emailAddress: String,
        displayName: String,
        imap: ServerEndpoint,
        smtp: ServerEndpoint,
        credentialRef: String,
        sortIndex: Int = 0,
        isEnabled: Bool = true,
        photoURL: String? = nil,
        syncLimit: Int? = nil
    ) {
        self.id = id
        self.provider = provider
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.imap = imap
        self.smtp = smtp
        self.credentialRef = credentialRef
        self.sortIndex = sortIndex
        self.isEnabled = isEnabled
        self.photoURL = photoURL
        self.syncLimit = syncLimit
    }
}

/// A host/port/security triple for one protocol endpoint.
public struct ServerEndpoint: Codable, Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var security: TransportSecurity

    public init(host: String, port: UInt16, security: TransportSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }
}

/// TLS posture for a connection.
public enum TransportSecurity: String, Codable, Sendable {
    /// TLS from the first byte (IMAPS 993 / SMTPS 465).
    case implicitTLS
    /// Plaintext connect, then upgrade via STARTTLS (SMTP submission 587).
    case startTLS
    /// No TLS. Only sane for a loopback Proton Bridge that terminates TLS
    /// itself; never used for a remote host.
    case plaintext
}
