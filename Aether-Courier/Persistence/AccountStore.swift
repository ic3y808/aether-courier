import Foundation
import EmailKit

/// Persists the list of configured `MailAccount`s as JSON in Application
/// Support. Accounts survive relaunches; their secrets are stored separately in
/// the Keychain (referenced by `MailAccount.credentialRef`).
struct AccountStore {
    private let url: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("accounts.json")
    }

    static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AetherCourier", isDirectory: true)
    }

    func load() -> [MailAccount] {
        guard let data = try? Data(contentsOf: url),
              let accounts = try? JSONDecoder().decode([MailAccount].self, from: data) else {
            return []
        }
        return accounts.sorted { $0.sortIndex < $1.sortIndex }
    }

    func save(_ accounts: [MailAccount]) throws {
        let data = try JSONEncoder().encode(accounts.sorted { $0.sortIndex < $1.sortIndex })
        try data.write(to: url, options: .atomic)
    }
}
