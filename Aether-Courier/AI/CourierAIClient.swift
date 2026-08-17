import Foundation
import EmailKit

/// The ONLY component that talks to the Aether backend. It sends copilot
/// prompts to the OpenAI-compatible `/v1/chat/completions` endpoint (same one
/// Aether-Terra uses) with the shared Aether token. It never touches mail
/// servers — mail is EmailKit's job.
actor CourierAIClient {
    private var host: String
    private var model: String
    /// Whether to attach the shared Aether token. Local servers (Ollama / LM
    /// Studio) don't need it, so it's skipped for local inference.
    private var sendToken: Bool
    private let session: URLSession

    // MARK: - Rate limiting / retry
    /// Minimum gap between outgoing requests — client-side pacing so a burst
    /// (e.g. the agent's multi-round loop) never hammers the backend.
    private let minInterval: TimeInterval = 0.35
    /// How many times to retry a rate-limited / transiently-failed request.
    private let maxRetries = 4
    /// When the last request was dispatched, for pacing.
    private var lastRequestAt: Date?

    init(host: String, model: String, sendToken: Bool = false) {
        self.host = host
        self.model = model
        self.sendToken = sendToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    /// One place every request goes through: paces requests, retries on
    /// rate-limit (429) / overload (503/529) / transient 5xx with exponential
    /// backoff honouring `Retry-After`, and maps final failures to typed errors.
    /// Actor isolation keeps `lastRequestAt` consistent across callers.
    private func send(_ request: URLRequest, label: String) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            // Pace: ensure at least `minInterval` since the previous dispatch.
            if let last = lastRequestAt {
                let gap = Date().timeIntervalSince(last)
                if gap < minInterval {
                    try await Task.sleep(nanoseconds: UInt64((minInterval - gap) * 1_000_000_000))
                }
            }
            lastRequestAt = Date()

            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }   // user hit stop — don't retry
                // Transient transport failure: retry a couple of times, then give up.
                if attempt < 2 {
                    attempt += 1
                    logWarn("AI: transport error (\(label)) — retry \(attempt) in \(backoffDescription(attempt))", category: "ai")
                    try await Task.sleep(nanoseconds: UInt64(backoff(attempt) * 1_000_000_000))
                    continue
                }
                logError("AI: transport error (\(label)): \(error.localizedDescription)", category: "ai")
                throw CourierAIError.transport
            }

            guard let http = response as? HTTPURLResponse else { throw CourierAIError.transport }
            if (200..<300).contains(http.statusCode) { return data }

            // Rate-limited / overloaded / transient server error → back off + retry.
            if Self.retryableStatus.contains(http.statusCode), attempt < maxRetries {
                attempt += 1
                let wait = retryAfter(http) ?? backoff(attempt)
                logWarn("AI: HTTP \(http.statusCode) (\(label)) — retry \(attempt)/\(maxRetries) in \(String(format: "%.1f", wait))s", category: "ai")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }

            let body = String(decoding: data.prefix(500), as: UTF8.self)
            logError("AI: HTTP \(http.statusCode) (\(label)) after \(attempt) retr\(attempt == 1 ? "y" : "ies") — \(body)", category: "ai")
            if http.statusCode == 429 || http.statusCode == 529 {
                throw CourierAIError.rateLimited(retryAfter: retryAfter(http))
            }
            throw CourierAIError.http(status: http.statusCode, body: body)
        }
    }

    private static let retryableStatus: Set<Int> = [429, 500, 502, 503, 529]

    /// Exponential backoff with jitter: ~0.5, 1, 2, 4s (capped at 8s).
    private func backoff(_ attempt: Int) -> TimeInterval {
        min(pow(2.0, Double(attempt - 1)) * 0.5, 8) + Double.random(in: 0...0.3)
    }
    private func backoffDescription(_ attempt: Int) -> String { String(format: "%.1fs", backoff(attempt)) }

    /// Honour a numeric `Retry-After` header (seconds), capped so we never hang.
    private func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let v = http.value(forHTTPHeaderField: "Retry-After"), let secs = Double(v) else { return nil }
        return min(max(secs, 0), 30)
    }

    func update(host: String, model: String, sendToken: Bool) {
        self.host = host
        self.model = model
        self.sendToken = sendToken
    }

    /// Lists available model IDs from the backend's OpenAI-compatible
    /// `/v1/models` endpoint (for the Settings model picker).
    func listModels() async -> [String] {
        guard let url = URL(string: normalized(host) + "/v1/models") else { return [] }
        var request = URLRequest(url: url)
        if sendToken, let token = Keychain.getString(account: "aether-backend-token") {
            request.setValue(token, forHTTPHeaderField: "X-Aether-Token")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logWarn("AI: /v1/models returned non-2xx", category: "ai")
                return []
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let ids = decoded.data.map(\.id).sorted()
            logInfo("AI: loaded \(ids.count) models", category: "ai")
            return ids
        } catch {
            logWarn("AI: failed to load models — \(error.localizedDescription)", category: "ai")
            return []
        }
    }

    private struct ModelsResponse: Codable {
        struct Model: Codable { let id: String }
        let data: [Model]
    }

    struct Message: Codable, Sendable { let role: String; let content: String }

    /// Sends a chat completion and returns the assistant's text.
    func complete(system: String, messages: [Message]) async throws -> String {
        guard let url = URL(string: normalized(host) + "/v1/chat/completions") else {
            logError("AI: bad host '\(host)'", category: "ai")
            throw CourierAIError.badHost
        }
        logInfo("AI: POST \(url.absoluteString) (model=\(model))", category: "ai")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if sendToken, let token = Keychain.getString(account: "aether-backend-token") {
            request.setValue(token, forHTTPHeaderField: "X-Aether-Token")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let payload = ChatRequest(
            model: model,
            messages: [Message(role: "system", content: system)] + messages,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await send(request, label: "chat")   // paced + retried
        logInfo("AI: HTTP 200, \(data.count) bytes", category: "ai")
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        // Tidy raw local-model output (reasoning blocks, meta-commentary) the way
        // the Aether hub used to — so local models read as cleanly as the backend.
        return AICleanup.sanitize(decoded.choices.first?.message.content ?? "")
    }

    /// Low-level chat POST for the agent loop. The caller builds the full JSON
    /// body (model, messages, tools) so only `Data` crosses the actor boundary;
    /// returns the raw response `Data`. Adds host + auth headers.
    func postChat(_ bodyJSON: Data) async throws -> Data {
        guard let url = URL(string: normalized(host) + "/v1/chat/completions") else { throw CourierAIError.badHost }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if sendToken, let token = Keychain.getString(account: "aether-backend-token") {
            request.setValue(token, forHTTPHeaderField: "X-Aether-Token")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyJSON
        return try await send(request, label: "agent")   // paced + retried
    }

    /// The active model id (for the agent body builder).
    var currentModel: String { model }

    private func normalized(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if !h.hasPrefix("http://") && !h.hasPrefix("https://") {
            // Bare IP/host:port → http (LAN hub); bare hostname → https.
            let isLAN = h.contains(":") || h.split(separator: ".").allSatisfy { UInt($0) != nil }
            h = (isLAN ? "http://" : "https://") + h
        }
        if h.hasSuffix("/") { h.removeLast() }
        return h
    }

    private struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let stream: Bool
    }
    private struct ChatResponse: Codable {
        struct Choice: Codable { let message: Message }
        let choices: [Choice]
    }
}

enum CourierAIError: Error, LocalizedError {
    case badHost
    case transport
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .badHost: return "The AI host is invalid. Set it in Settings → AI."
        case .transport: return "Could not reach the AI server. Is Ollama/LM Studio (or the hub) running?"
        case .rateLimited(let after):
            if let after { return "The AI is rate-limited — try again in about \(Int(after.rounded()))s." }
            return "The AI is rate-limited (too many requests). Give it a moment and try again."
        case .http(let status, _):
            if status == 404 { return "Model not found (HTTP 404). Open Settings → AI and pick an installed model." }
            return "AI server returned HTTP \(status)."
        }
    }
}
