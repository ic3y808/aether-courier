import SwiftUI
import EmailKit

/// Smart category and attribute filters for the message list.
enum MessageFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case primary      = "Primary"
    case unread       = "Unread"
    case attachments  = "Attachments"
    case starred      = "Starred"
    case promotions   = "Promotions"
    case shopping     = "Shopping"
    case social       = "Social"
    case vip          = "VIP / Direct"

    var id: String { rawValue }
    var title: String { rawValue }

    var iconName: String {
        switch self {
        case .primary: return "person.fill"
        case .unread: return "envelope.badge.fill"
        case .attachments: return "paperclip"
        case .starred: return "star.fill"
        case .promotions: return "megaphone.fill"
        case .shopping: return "cart.fill"
        case .social: return "message.fill"
        case .vip: return "person.crop.circle.badge.star"
        }
    }

    var accentColor: Color {
        switch self {
        case .primary: return .aetherAccent
        case .unread: return .indigo
        case .attachments: return .teal
        case .starred: return .yellow
        case .promotions: return Color(red: 0.92, green: 0.22, blue: 0.52)
        case .shopping: return .orange
        case .social: return .purple
        case .vip: return .mint
        }
    }

    var bannerTitle: String {
        switch self {
        case .promotions: return "Special Offers, Deals, and More"
        case .shopping: return "Orders, Receipts & Deliveries"
        case .social: return "Social Notifications & Activity"
        case .unread: return "Unread Inbox Filter"
        case .attachments: return "Files & Attachments Filter"
        case .starred: return "Starred Messages Filter"
        case .vip: return "VIP Direct Messages Filter"
        case .primary: return "Primary Inbox"
        }
    }

    var descriptionBanner: String? {
        switch self {
        case .promotions:
            return "See what's new from businesses and organizations you recognize."
        case .shopping:
            return "Track your online purchases, shipping updates, and order receipts."
        case .social:
            return "Messages from social networks, forums, and community discussions."
        case .unread:
            return "Focus strictly on unread emails waiting for your response."
        case .attachments:
            return "Messages containing attached documents, photos, or files."
        case .starred:
            return "Important messages marked for review."
        case .vip:
            return "Priority emails sent directly to you from key contacts."
        case .primary:
            return nil
        }
    }

    /// Evaluates if a message matches this filter criteria.
    func matches(_ m: MailMessage) -> Bool {
        switch self {
        case .primary:
            return true
        case .unread:
            return m.isUnread
        case .attachments:
            return m.hasAttachments
        case .starred:
            return m.flags.contains(.flagged)
        case .promotions:
            let s = (m.subject + " " + (m.from.first?.address ?? "") + " " + m.snippet).lowercased()
            return s.contains("sale") || s.contains("deal") || s.contains("off") || s.contains("discount")
                || s.contains("promo") || s.contains("offer") || s.contains("newsletter") || s.contains("coupon")
                || s.contains("unsubscribe")
        case .shopping:
            let s = (m.subject + " " + (m.from.first?.address ?? "") + " " + m.snippet).lowercased()
            return s.contains("order") || s.contains("receipt") || s.contains("tracking") || s.contains("shipped")
                || s.contains("shipping") || s.contains("delivery") || s.contains("amazon") || s.contains("invoice")
        case .social:
            let s = (m.subject + " " + (m.from.first?.address ?? "") + " " + m.snippet).lowercased()
            return s.contains("social") || s.contains("github") || s.contains("twitter") || s.contains("linkedin")
                || s.contains("comment") || s.contains("followed") || s.contains("mention") || s.contains("discord")
        case .vip:
            return !m.from.isEmpty && (m.from.first?.name != nil || m.flags.contains(.flagged))
        }
    }
}
