import Foundation

/// The email services Aether-Courier can connect to.
///
/// Each provider maps to a concrete transport + auth strategy resolved through
/// `ProviderCatalog`. `proton` connects to a locally-running Proton Mail Bridge
/// (there is no public Proton IMAP endpoint), and `custom` lets a user point at
/// any IMAP/SMTP host by hand.
public enum MailProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case icloud
    case gmail
    case outlook
    case proton
    case custom

    public var id: String { rawValue }

    /// Human-facing name for pickers and account chips.
    public var displayName: String {
        switch self {
        case .icloud:  return "iCloud"
        case .gmail:   return "Gmail"
        case .outlook: return "Outlook"
        case .proton:  return "Proton Mail"
        case .custom:  return "Other (IMAP)"
        }
    }

    /// How the account authenticates to IMAP/SMTP.
    public var authKind: MailAuthKind {
        switch self {
        case .icloud:  return .appPassword   // app-specific password over LOGIN
        case .gmail:   return .oauth          // XOAUTH2 (PKCE)
        case .outlook: return .oauth          // XOAUTH2 (PKCE)
        case .proton:  return .bridge         // Bridge-issued credentials, localhost
        case .custom:  return .password
        }
    }

    /// Whether new-mail delivery uses IMAP IDLE (true for every supported
    /// provider today — the app never falls back to timed polling).
    public var supportsIdle: Bool { true }
}

/// The credential model a provider expects.
public enum MailAuthKind: String, Codable, Sendable {
    /// Standard IMAP/SMTP LOGIN with a user-supplied password.
    case password
    /// Apple app-specific password (still LOGIN, but labelled for UX guidance).
    case appPassword
    /// OAuth2 access token presented via the SASL XOAUTH2 mechanism.
    case oauth
    /// Proton Mail Bridge — credentials issued by the local Bridge app.
    case bridge
}
