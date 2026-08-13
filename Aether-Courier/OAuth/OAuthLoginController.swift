import Foundation
import AppKit
import AuthenticationServices
import EmailKit

/// Drives the interactive OAuth2 + PKCE flow for Gmail/Outlook using
/// `ASWebAuthenticationSession`. The deterministic pieces (PKCE, URL building,
/// token bodies) come from EmailKit's `OAuthPKCE`; this class only owns the
/// browser presentation and the network exchange.
@MainActor
final class OAuthLoginController: NSObject, ASWebAuthenticationPresentationContextProviding {

    private var session: ASWebAuthenticationSession?

    /// Runs the full flow and returns the issued tokens.
    func signIn(config: OAuthConfig) async throws -> OAuthTokens {
        let pkce = OAuthPKCE.generatePair()
        let state = UUID().uuidString
        guard let authURL = OAuthPKCE.authorizationURL(config: config, state: state, challenge: pkce.challenge) else {
            throw OAuthLoginError.badConfiguration
        }
        logInfo("OAuth: presenting auth URL \(authURL.absoluteString)", category: "oauth")
        let scheme = String(config.redirectURI.split(separator: ":").first ?? "com.aether.courier")

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce()
            // The completion handler MUST be @Sendable: ASWebAuthenticationSession
            // invokes it on a background XPC queue, so it cannot inherit this
            // @MainActor class's isolation (doing so traps under Swift 6).
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { @Sendable url, error in
                guard once.claim() else { return }
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? OAuthLoginError.cancelled) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start(), once.claim() {
                cont.resume(throwing: OAuthLoginError.cannotStart)
            }
        }

        // Validate state and pull the authorization code.
        let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw OAuthLoginError.stateMismatch
        }
        if let err = items.first(where: { $0.name == "error" })?.value {
            throw OAuthLoginError.provider(err)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw OAuthLoginError.noCode
        }

        // Exchange the code for tokens.
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(OAuthPKCE.tokenExchangeBody(config: config, code: code, verifier: pkce.verifier).utf8)
        logInfo("OAuth: token exchange POST \(config.tokenEndpoint.absoluteString) redirect=\(config.redirectURI)", category: "oauth")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let body = String(decoding: data, as: UTF8.self)
        guard let http, (200..<300).contains(http.statusCode) else {
            logError("OAuth: token exchange failed HTTP \(http?.statusCode ?? -1) — \(body)", category: "oauth")
            throw OAuthLoginError.exchangeFailed
        }
        logInfo("OAuth: token exchange OK (HTTP \(http.statusCode))", category: "oauth")
        do {
            return try JSONDecoder().decode(OAuthTokens.self, from: data)
        } catch {
            logError("OAuth: token JSON decode failed — \(body)", category: "oauth")
            throw OAuthLoginError.exchangeFailed
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}

/// Ensures a continuation is resumed exactly once across the completion handler
/// and the `start()`-failed path (double-resume is a fatalError).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum OAuthLoginError: Error, LocalizedError {
    case badConfiguration, cancelled, cannotStart, stateMismatch, noCode, exchangeFailed
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .badConfiguration: return "OAuth is not configured. Add the client ID in Settings → Providers."
        case .cancelled: return "Sign-in was cancelled."
        case .cannotStart: return "Could not start the sign-in session."
        case .stateMismatch: return "OAuth state mismatch — possible tampering. Try again."
        case .noCode: return "No authorization code was returned."
        case .exchangeFailed: return "Exchanging the authorization code for tokens failed."
        case .provider(let e): return "Provider returned an error: \(e)"
        }
    }
}
