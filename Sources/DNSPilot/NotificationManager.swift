import Foundation
import UserNotifications

/// Notifications macOS : bascule auto par SSID, failover, rétablissement.
/// Désactivables dans les Préférences. Nécessite le bundle .app —
/// via `swift run`, les notifications sont simplement journalisées.
final class NotificationManager {

    static let shared = NotificationManager()
    private init() {}

    func post(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: PreferenceKeys.notifications) else { return }
        guard AppInfo.isBundled else {
            NSLog("DNSPilot: notification (hors bundle) — %@ : %@", title, body)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
