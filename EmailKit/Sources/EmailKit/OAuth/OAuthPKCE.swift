import Foundation
import CryptoKit

/// Pure PKCE (RFC 7636) + OAuth2 authorization-code helpers. The interactive
/// browser step (`ASWebAuthenticationSession`) lives in the app; everything
/// deterministic — code verifier/challenge, the authorization URL, and the
/// token-exchange request bodies — is here so it can be unit-tested.
public enum OAuthPKCE {

    /// A generated verifier/challenge pair for one auth attempt.
    public struct Pair: Equatable, Sendable {
        public let verifier: String
        public let challenge: String
        public let method = "S256"
    }

    /// Generates a high-entropy code verifier and its S256 challenge.
    public static func generatePair() -> Pair {
        let verifier = randomVerifier()
        return Pair(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// 43–128 chars of unreserved characters (RFC 7636 §4.1).
    public static func randomVerifier(byteCount: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    /// S256 challenge = BASE64URL(SHA256(verifier)).
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// Builds the authorization URL the user is sent to.
    public static func authorizationURL(config: OAuthConfig, state: String, challenge: String) -> URL? {
        var comps = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        for (k, v) in config.extraAuthParams.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: k, value: v))
        }
        comps?.queryItems = items
        return comps?.url
    }

    /// Form body for exchanging an authorization code for tokens. A
    /// `clientSecret` is included when present — Google Desktop/Web clients
    /// require it (for installed apps the secret is not truly confidential);
    /// iOS/PKCE public clients omit it.
    public static func tokenExchangeBody(config: OAuthConfig, code: String, verifier: String) -> String {
        var params = [
            "client_id": config.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier
        ]
        if let secret = config.clientSecret, !secret.isEmpty { params["client_secret"] = secret }
        return formURLEncoded(params)
    }

    /// Form body for refreshing an access token.
    public static func refreshBody(config: OAuthConfig, refreshToken: String) -> String {
        var params = [
            "client_id": config.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if let secret = config.clientSecret, !secret.isEmpty { params["client_secret"] = secret }
        return formURLEncoded(params)
    }

    /// The SASL XOAUTH2 initial client response, base64-encoded, used by both
    /// IMAP `AUTHENTICATE XOAUTH2` and SMTP `AUTH XOAUTH2`.
    /// Format: `user=<email>^Aauth=Bearer <token>^A^A` where ^A = 0x01.
    public static func xoauth2String(user: String, accessToken: String) -> String {
        let ctrlA = "\u{01}"
        let raw = "user=\(user)\(ctrlA)auth=Bearer \(accessToken)\(ctrlA)\(ctrlA)"
        return Data(raw.utf8).base64EncodedString()
    }

    // MARK: encoding helpers

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formURLEncoded(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

/// The token set returned by an OAuth exchange/refresh.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt
    }

    /// Decodes a token endpoint JSON response, converting `expires_in` seconds
    /// into an absolute `expiresAt`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try c.decode(String.self, forKey: .accessToken)
        self.refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        if let expiresIn = try c.decodeIfPresent(Double.self, forKey: .expiresIn) {
            self.expiresAt = Date().addingTimeInterval(expiresIn)
        } else {
            self.expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60) // refresh 60s early
    }
}
