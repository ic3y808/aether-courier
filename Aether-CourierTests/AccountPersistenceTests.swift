import Testing
import Foundation
@testable import Aether_Courier
import EmailKit

/// App-layer tests that don't require a live server: account persistence
/// round-trips and settings encoding. (The mail protocol itself is covered
/// exhaustively by EmailKitTests.)
@Suite("Account persistence")
struct AccountPersistenceTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("courier-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("accounts survive a save/load round-trip")
    func roundTrip() throws {
        let store = AccountStore(directory: tempDir())
        let account = MailAccount(
            provider: .icloud,
            emailAddress: "me@icloud.com",
            displayName: "Me",
            imap: ProviderCatalog.imap(for: .icloud),
            smtp: ProviderCatalog.smtp(for: .icloud),
            credentialRef: "account-1",
            sortIndex: 0
        )
        try store.save([account])
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.emailAddress == "me@icloud.com")
        #expect(loaded.first?.provider == .icloud)
        #expect(loaded.first?.imap.port == 993)
    }

    @Test("accounts load sorted by sortIndex")
    func sorted() throws {
        let store = AccountStore(directory: tempDir())
        let a = MailAccount(provider: .gmail, emailAddress: "b@x.com", displayName: "B",
                            imap: ProviderCatalog.imap(for: .gmail), smtp: ProviderCatalog.smtp(for: .gmail),
                            credentialRef: "b", sortIndex: 1)
        let b = MailAccount(provider: .icloud, emailAddress: "a@x.com", displayName: "A",
                            imap: ProviderCatalog.imap(for: .icloud), smtp: ProviderCatalog.smtp(for: .icloud),
                            credentialRef: "a", sortIndex: 0)
        try store.save([a, b])
        let loaded = store.load()
        #expect(loaded.map(\.emailAddress) == ["a@x.com", "b@x.com"])
    }

    @Test("settings encode and decode")
    func settings() throws {
        var s = CourierSettings()
        s.backendHost = "mail.example.com:3000"
        s.googleClientID = "CID"
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(CourierSettings.self, from: data)
        #expect(decoded.backendHost == "mail.example.com:3000")
        #expect(decoded.googleClientID == "CID")
        #expect(decoded.fetchWindow == 60)
    }
}
