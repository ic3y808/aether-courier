import Foundation

/// Canonical server coordinates and OAuth parameters for each supported
/// provider. This is the single source of truth for "how do we reach iCloud /
/// Gmail / Outlook / Proton" so the add-account UI never hardcodes hosts.
public enum ProviderCatalog {

    /// Default IMAP endpoint for a provider.
    public static func imap(for provider: MailProvider) -> ServerEndpoint {
        switch provider {
        case .icloud:
            return ServerEndpoint(host: "imap.mail.me.com", port: 993, security: .implicitTLS)
        case .gmail:
            return ServerEndpoint(host: "imap.gmail.com", port: 993, security: .implicitTLS)
        case .outlook:
            return ServerEndpoint(host: "outlook.office365.com", port: 993, security: .implicitTLS)
        case .proton:
            // Proton Mail Bridge listens on loopback; it terminates TLS itself
            // and by default speaks STARTTLS on 1143.
            return ServerEndpoint(host: "127.0.0.1", port: 1143, security: .startTLS)
        case .custom:
            return ServerEndpoint(host: "", port: 993, security: .implicitTLS)
        }
    }

    /// Default SMTP submission endpoint for a provider.
    public static func smtp(for provider: MailProvider) -> ServerEndpoint {
        switch provider {
        case .icloud:
            return ServerEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS)
        case .gmail:
            return ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .implicitTLS)
        case .outlook:
            return ServerEndpoint(host: "smtp.office365.com", port: 587, security: .startTLS)
        case .proton:
            return ServerEndpoint(host: "127.0.0.1", port: 1025, security: .startTLS)
        case .custom:
            return ServerEndpoint(host: "", port: 587, security: .startTLS)
        }
    }

    /// OAuth configuration for providers that use XOAUTH2. Returns nil for
    /// password/app-password/bridge providers. The `clientID` is injected by
    /// the app (registered by the user in Google Cloud / Azure Entra) — the
    /// catalog only supplies the fixed endpoints, scopes, and redirect.
    public static func oauth(for provider: MailProvider, clientID: String, clientSecret: String? = nil, tenant: String? = nil) -> OAuthConfig? {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }
        switch provider {
        case .gmail:
            // Google rejects arbitrary custom schemes; a native (iOS-type)
            // client must use the REVERSED client-ID scheme as its redirect,
            // e.g. client "123-abc.apps.googleusercontent.com" →
            // "com.googleusercontent.apps.123-abc:/oauth2redirect". Google
            // accepts this automatically for iOS clients (nothing to register).
            let reversed = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            return OAuthConfig(
                clientID: clientID,
                clientSecret: clientSecret,
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                // mail.google.com = full IMAP/SMTP via XOAUTH2; openid+profile
                // let us read the account's display name and profile photo.
                scopes: ["https://mail.google.com/", "openid",
                         "https://www.googleapis.com/auth/userinfo.profile"],
                redirectURI: "com.googleusercontent.apps.\(reversed):/oauth2redirect",
                extraAuthParams: ["access_type": "offline", "prompt": "consent"]
            )
        case .outlook:
            let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("GOCSPX-") else { return nil }
            let t = (tenant?.isEmpty == false) ? tenant! : "common"
            return OAuthConfig(
                clientID: clientID,
                authorizationEndpoint: URL(string: "https://login.microsoftonline.com/\(t)/oauth2/v2.0/authorize")!,
                tokenEndpoint: URL(string: "https://login.microsoftonline.com/\(t)/oauth2/v2.0/token")!,
                scopes: [
                    "https://outlook.office.com/IMAP.AccessAsUser.All",
                    "https://outlook.office.com/SMTP.Send",
                    "offline_access"
                ],
                redirectURI: "com.aether.courier://oauth2redirect/microsoft",
                extraAuthParams: ["prompt": "select_account"]
            )
        case .icloud, .proton, .custom:
            return nil
        }
    }

    /// UX guidance shown in the add-account sheet for each provider.
    public static func setupHint(for provider: MailProvider) -> String {
        switch provider {
        case .icloud:
            return "iCloud requires an app-specific password. Generate one at appleid.apple.com → Sign-In & Security → App-Specific Passwords, then paste it here."
        case .gmail:
            return "Sign in with Google. Requires a Google Cloud OAuth client of type iOS (bundle id com.aether.courier) — its client ID goes in Settings → Providers. Desktop/Web clients won't work (custom-scheme redirect)."
        case .outlook:
            return "Sign in with Microsoft. Requires an Azure Entra app (Mobile & desktop) client ID configured in Settings → Providers."
        case .proton:
            return "Proton has no public IMAP. Install and run Proton Mail Bridge (paid plan), then paste the Bridge-issued username and password. Host defaults to 127.0.0.1."
        case .custom:
            return "Enter your provider's IMAP and SMTP host, port, and credentials manually."
        }
    }
}

/// OAuth2 (PKCE, public client) configuration for a provider.
public struct OAuthConfig: Sendable, Hashable {
    public var clientID: String
    /// Required by Google Desktop/Web clients in the token exchange; nil for
    /// iOS/PKCE public clients and Microsoft mobile & desktop clients.
    public var clientSecret: String?
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var scopes: [String]
    public var redirectURI: String
    public var extraAuthParams: [String: String]

    public init(
        clientID: String,
        clientSecret: String? = nil,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        scopes: [String],
        redirectURI: String,
        extraAuthParams: [String: String] = [:]
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.extraAuthParams = extraAuthParams
    }
}
