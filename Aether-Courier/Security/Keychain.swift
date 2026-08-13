import Foundation
import Security

/// Local secrets store that persists credentials to Application Support/Aether-Courier/secrets.json.
/// This completely bypasses macOS Keychain ACL prompts that occur when rebuilds re-sign the app.
private final class LocalSecretsStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = LocalSecretsStore()
    private let fileURL: URL
    private var cache: [String: String] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Aether-Courier", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("secrets.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        cache = dict
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? (fileURL as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
    }

    func get(_ account: String) -> String? {
        cache[account]
    }

    func set(_ value: String, account: String) {
        cache[account] = value
        save()
    }

    func delete(_ account: String) {
        cache.removeValue(forKey: account)
        save()
    }
}

/// Thin wrapper over per-account mail secrets (app passwords, Bridge passwords,
/// and serialized OAuth token sets). Stores secrets in Application Support
/// to prevent macOS Keychain prompts on rebuilds.
enum Keychain {
    static let service = "com.aether.courier.credentials"

    static func set(_ value: Data, account: String) {
        let encoded = value.base64EncodedString()
        LocalSecretsStore.shared.set(encoded, account: account)
    }

    static func get(account: String) -> Data? {
        guard let encoded = LocalSecretsStore.shared.get(account), let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return data
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        LocalSecretsStore.shared.delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        return true
    }

    // MARK: string / codable convenience

    static func setString(_ value: String, account: String) {
        set(Data(value.utf8), account: account)
    }

    static func getString(account: String) -> String? {
        get(account: account).map { String(decoding: $0, as: UTF8.self) }
    }

    static func setCodable<T: Encodable>(_ value: T, account: String) throws {
        set(try JSONEncoder().encode(value), account: account)
    }

    static func getCodable<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = get(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
