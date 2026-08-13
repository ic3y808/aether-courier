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

    init(host: String, model: String, sendToken: Bool = false) {
        self.host = host
        self.model = model
        self.sendToken = sendToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
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

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logError("AI: transport error to \(url.absoluteString): \(error.localizedDescription)", category: "ai")
            throw CourierAIError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw CourierAIError.transport }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            logError("AI: HTTP \(http.statusCode) from \(url.absoluteString). Hint: 405 usually means the host isn't the Aether Cortex (e.g. Docker/other service on :3000). Body: \(body)", category: "ai")
            throw CourierAIError.http(status: http.statusCode, body: body)
        }
        logInfo("AI: HTTP 200, \(data.count) bytes", category: "ai")
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CourierAIError.transport }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            logError("Agent: HTTP \(http.statusCode) — \(body)", category: "ai")
            throw CourierAIError.http(status: http.statusCode, body: body)
        }
        return data
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
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .badHost: return "The AI host is invalid. Set it in Settings → AI."
        case .transport: return "Could not reach the AI server. Is Ollama/LM Studio (or the hub) running?"
        case .http(let status, _):
            if status == 404 { return "Model not found (HTTP 404). Open Settings → AI and pick an installed model." }
            return "AI server returned HTTP \(status)."
        }
    }
}
