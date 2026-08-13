import SwiftUI
import CryptoKit
import EmailKit

/// Loads and caches account profile photos. Prefers an explicit `photoURL`
/// (e.g. the Google account picture), otherwise tries Gravatar keyed on the
/// email hash. Returns nil when neither exists so the UI can fall back to
/// colored initials.
actor AvatarCache {
    static let shared = AvatarCache()
    private var cache: [String: NSImage] = [:]
    private var misses: Set<String> = []

    func image(email: String, photoURL: String?) async -> NSImage? {
        let key = email.lowercased()
        if let cached = cache[key] { return cached }
        if misses.contains(key) { return nil }

        // 1. Explicit photo URL (Gmail/Google).
        if let photoURL, let url = URL(string: photoURL), let img = await fetch(url) {
            cache[key] = img; return img
        }
        // 2. Gravatar (d=404 → 404 when the address has no gravatar).
        let hash = Self.md5Hex(key)
        if let url = URL(string: "https://www.gravatar.com/avatar/\(hash)?d=404&s=200"),
           let img = await fetch(url) {
            cache[key] = img; return img
        }
        misses.insert(key)
        return nil
    }

    private func fetch(_ url: URL) async -> NSImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// An account avatar: the real profile photo when available, else rich provider service icon.
struct AccountAvatarView: View {
    let account: MailAccount
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
            } else {
                ProviderServiceIconView(account: account)
            }
        }
        .task(id: account.id) {
            image = await AvatarCache.shared.image(email: account.emailAddress, photoURL: account.photoURL)
        }
    }

    static func providerTint(_ provider: MailProvider) -> Color {
        switch provider {
        case .icloud:  return .cyan
        case .gmail:   return .red
        case .outlook: return .blue
        case .proton:  return .purple
        case .custom:  return .gray
        }
    }
}

/// Renders a rich service-branded icon when a user profile photo is not loaded.
/// Shows Gmail, Outlook, iCloud, or Proton service identity clearly.
struct ProviderServiceIconView: View {
    let account: MailAccount

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundGradient)

            iconSymbol
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var iconSymbol: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                switch account.provider {
                case .gmail:
                    Image(systemName: "envelope.fill")
                        .font(.system(size: s * 0.46, weight: .bold))
                case .outlook:
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: s * 0.44, weight: .bold))
                case .icloud:
                    Image(systemName: "apple.logo")
                        .font(.system(size: s * 0.46, weight: .semibold))
                        .offset(y: -s * 0.02)
                case .proton:
                    Image(systemName: "shield.checkered")
                        .font(.system(size: s * 0.46, weight: .bold))
                case .custom:
                    Image(systemName: "server.rack")
                        .font(.system(size: s * 0.42, weight: .semibold))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var backgroundGradient: LinearGradient {
        switch account.provider {
        case .gmail:
            return LinearGradient(colors: [Color(red: 0.92, green: 0.26, blue: 0.21), Color(red: 0.8, green: 0.15, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .outlook:
            return LinearGradient(colors: [Color(red: 0.0, green: 0.47, blue: 0.84), Color(red: 0.0, green: 0.32, blue: 0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .icloud:
            return LinearGradient(colors: [Color(red: 0.2, green: 0.6, blue: 1.0), Color(red: 0.05, green: 0.4, blue: 0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .proton:
            return LinearGradient(colors: [Color(red: 0.44, green: 0.34, blue: 0.85), Color(red: 0.3, green: 0.2, blue: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .custom:
            return LinearGradient(colors: [.gray, Color(white: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
