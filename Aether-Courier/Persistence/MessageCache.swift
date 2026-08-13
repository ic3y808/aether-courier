import Foundation
import EmailKit

/// On-disk cache of fetched message envelopes + folder lists so the mailbox
/// shows instantly on launch and survives restarts. Bodies are NOT cached (they
/// re-fetch on open); this stores the light list data keyed by account UUID.
struct MessageCache {
    private let url: URL

    init(directory: URL? = nil) {
        let base = (directory ?? AccountStore.defaultDirectory()).appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("messages.json")
    }

    struct Snapshot: Codable {
        var messagesByAccount: [String: [MailMessage]] = [:]
        var inboxPath: [String: String] = [:]
        var foldersByAccount: [String: [MailFolder]] = [:]
        var loadedFolders: [String] = []
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
