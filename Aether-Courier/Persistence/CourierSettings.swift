import Foundation

/// App-wide settings persisted to UserDefaults (non-secret). OAuth *client IDs*
/// are configuration a user registers with Google/Microsoft, not secrets, so
/// they live here; issued tokens live in the Keychain.
///
/// Decoding is deliberately tolerant of missing keys (custom `init(from:)`) so
/// adding a new field in a future build never wipes a user's saved settings.
struct CourierSettings: Codable, Equatable {
    /// Optional remote OpenAI-compatible host used ONLY for AI copilot calls when
    /// local inference is off. Empty by default (the app ships with local AI on).
    var backendHost: String = ""
    /// When true, the copilot talks to a LOCAL OpenAI-compatible server (Ollama
    /// / LM Studio) on this Mac. Default on.
    var aiUseLocal: Bool = true
    /// Local inference host (Ollama default 11434; LM Studio uses 1234).
    var localAIHost: String = "127.0.0.1:11434"
    /// Model id passed to `/v1/chat/completions`. Any model your Ollama/LM Studio
    /// serves works — pick it in Settings → Model.
    var aiModel: String = "llama3.1:8b"
    /// Google Cloud OAuth client ID (for Gmail).
    var googleClientID: String = ""
    /// Azure Entra app client ID (for Outlook).
    var microsoftClientID: String = ""
    /// Azure Entra tenant type: "common" (Multitenant & Personal), "consumers" (Personal Only), or "organizations".
    var microsoftTenant: String = "common"
    /// Number of recent messages to fetch per folder on sync.
    var fetchWindow: Int = 60
    /// When true, remote images in HTML emails load automatically (default off).
    var loadRemoteImages: Bool = false
    /// Blocked sender addresses (lowercased); their mail auto-moves to Junk.
    var blockedSenders: [String] = []
    /// macOS system sound played when new mail arrives ("None" = silent).
    var notificationSound: String = "Glass"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case backendHost, aiUseLocal, localAIHost, aiModel, googleClientID
        case microsoftClientID, microsoftTenant, fetchWindow, loadRemoteImages, blockedSenders
        case notificationSound
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CourierSettings()   // defaults
        backendHost      = (try? c.decode(String.self, forKey: .backendHost)) ?? d.backendHost
        aiUseLocal       = (try? c.decode(Bool.self, forKey: .aiUseLocal)) ?? d.aiUseLocal
        localAIHost      = (try? c.decode(String.self, forKey: .localAIHost)) ?? d.localAIHost
        aiModel          = (try? c.decode(String.self, forKey: .aiModel)) ?? d.aiModel
        googleClientID   = (try? c.decode(String.self, forKey: .googleClientID)) ?? d.googleClientID
        microsoftClientID = (try? c.decode(String.self, forKey: .microsoftClientID)) ?? d.microsoftClientID
        microsoftTenant  = (try? c.decode(String.self, forKey: .microsoftTenant)) ?? d.microsoftTenant
        fetchWindow      = (try? c.decode(Int.self, forKey: .fetchWindow)) ?? d.fetchWindow
        loadRemoteImages = (try? c.decode(Bool.self, forKey: .loadRemoteImages)) ?? d.loadRemoteImages
        blockedSenders   = (try? c.decode([String].self, forKey: .blockedSenders)) ?? d.blockedSenders
        notificationSound = (try? c.decode(String.self, forKey: .notificationSound)) ?? d.notificationSound
    }

    /// The macOS system sounds available for new-mail alerts (plus "None").
    static let availableSounds: [String] = {
        let dir = "/System/Library/Sounds"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted() ?? ["Glass"]
        return ["None"] + names
    }()

    /// Trims stray whitespace/newlines from user-entered string fields.
    func sanitized() -> CourierSettings {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var s = self
        s.backendHost = t(backendHost)
        s.localAIHost = t(localAIHost)
        s.aiModel = t(aiModel)
        s.googleClientID = t(googleClientID)
        s.microsoftClientID = t(microsoftClientID)
        s.microsoftTenant = t(microsoftTenant).isEmpty ? "common" : t(microsoftTenant)
        return s
    }

    private static let key = "com.aether.courier.settings"

    static func load() -> CourierSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var s = try? JSONDecoder().decode(CourierSettings.self, from: data) else {
            return CourierSettings()
        }
        if s.aiModel == "aether" || s.aiModel.isEmpty { s.aiModel = CourierSettings().aiModel }
        // Migrate legacy "consumers" setting to "common" (Any Entra ID Tenant + Personal Microsoft accounts)
        if s.microsoftTenant == "consumers" {
            s.microsoftTenant = "common"
            s.save()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
