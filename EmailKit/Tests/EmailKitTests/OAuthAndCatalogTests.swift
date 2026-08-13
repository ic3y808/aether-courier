import Testing
import Foundation
import CryptoKit
@testable import EmailKit

@Suite("OAuth PKCE")
struct OAuthPKCETests {

    @Test("S256 challenge matches SHA256(verifier) base64url")
    func challenge() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = OAuthPKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        #expect(OAuthPKCE.challenge(for: verifier) == expected)
    }

    @Test("generated verifier is URL-safe and long enough")
    func verifier() {
        let pair = OAuthPKCE.generatePair()
        #expect(pair.verifier.count >= 43)
        #expect(pair.verifier.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains($0) })
        #expect(pair.challenge == OAuthPKCE.challenge(for: pair.verifier))
    }

    @Test("authorization URL carries PKCE + scopes")
    func authURL() throws {
        let cfg = ProviderCatalog.oauth(for: .gmail, clientID: "CID.apps.googleusercontent.com")!
        let url = OAuthPKCE.authorizationURL(config: cfg, state: "xyz", challenge: "CHAL")!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "CID.apps.googleusercontent.com")
        #expect(items["code_challenge"] == "CHAL")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["response_type"] == "code")
        #expect(items["scope"]?.contains("https://mail.google.com/") == true)
        #expect(items["access_type"] == "offline")
    }

    @Test("token exchange body is form-encoded with verifier")
    func tokenBody() {
        let cfg = ProviderCatalog.oauth(for: .outlook, clientID: "abc")!
        let body = OAuthPKCE.tokenExchangeBody(config: cfg, code: "the code", verifier: "ver")
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=the%20code"))
        #expect(body.contains("code_verifier=ver"))
    }

    @Test("XOAUTH2 SASL string encodes user + bearer with ^A separators")
    func xoauth2() {
        let s = OAuthPKCE.xoauth2String(user: "u@x.com", accessToken: "TOKEN")
        let decoded = String(data: Data(base64Encoded: s)!, encoding: .utf8)!
        #expect(decoded == "user=u@x.com\u{01}auth=Bearer TOKEN\u{01}\u{01}")
    }

    @Test("token JSON decodes expires_in into an absolute date")
    func tokenDecode() throws {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#
        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
        #expect(tokens.accessToken == "AT")
        #expect(tokens.refreshToken == "RT")
        #expect(tokens.expiresAt != nil)
        #expect(tokens.isExpired == false)
    }
}

@Suite("Provider catalog")
struct ProviderCatalogTests {

    @Test("iCloud uses app-password + IMAPS 993")
    func icloud() {
        #expect(MailProvider.icloud.authKind == .appPassword)
        let imap = ProviderCatalog.imap(for: .icloud)
        #expect(imap.host == "imap.mail.me.com")
        #expect(imap.port == 993)
        #expect(imap.security == .implicitTLS)
        #expect(ProviderCatalog.oauth(for: .icloud, clientID: "x") == nil)
    }

    @Test("Gmail + Outlook are OAuth providers")
    func oauthProviders() {
        #expect(MailProvider.gmail.authKind == .oauth)
        #expect(MailProvider.outlook.authKind == .oauth)
        #expect(ProviderCatalog.oauth(for: .gmail, clientID: "x") != nil)
        #expect(ProviderCatalog.oauth(for: .outlook, clientID: "x") != nil)
    }

    @Test("Proton defaults to the local Bridge on STARTTLS")
    func proton() {
        #expect(MailProvider.proton.authKind == .bridge)
        let imap = ProviderCatalog.imap(for: .proton)
        let smtp = ProviderCatalog.smtp(for: .proton)
        #expect(imap.host == "127.0.0.1")
        #expect(imap.port == 1143)
        #expect(imap.security == .startTLS)
        #expect(smtp.host == "127.0.0.1")
        #expect(smtp.port == 1025)
        #expect(smtp.security == .startTLS)
    }

    @Test("every provider supports IDLE (never polls)")
    func idle() {
        #expect(MailProvider.allCases.allSatisfy { $0.supportsIdle })
    }
}
