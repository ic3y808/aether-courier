import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for new-mail banners. The app's
/// chosen system *sound* is played separately (NSSound), so these banners are
/// silent to avoid a double chime.
enum MailNotifier {

    /// Ask for permission once (call at launch). Harmless to call repeatedly.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { granted, error in
            if let error {
                logWarn("notify: authorization error — \(error.localizedDescription)", category: "notify")
            } else {
                logInfo("notify: authorization \(granted ? "granted" : "denied")", category: "notify")
            }
        }
    }

    /// Post a new-mail banner. `id` (the message id) dedupes repeats.
    static func post(title: String, body: String, id: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // No content.sound — the app plays the user's chosen NSSound itself.
            let request = UNNotificationRequest(identifier: "mail-\(id)", content: content, trigger: nil)
            center.add(request) { error in
                if let error { logWarn("notify: post failed — \(error.localizedDescription)", category: "notify") }
            }
        }
    }
}
