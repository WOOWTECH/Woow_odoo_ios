import Foundation
import UserNotifications

/// Builds and displays push notifications from FCM data payloads.
/// Ported from Android: NotificationHelper.kt
enum NotificationService {

    /// Builds notification content from FCM data payload.
    /// Returns nil if required fields (title, body) are missing.
    static func buildContent(from data: [String: String]) -> UNMutableNotificationContent? {
        guard let title = data["title"], !title.isEmpty,
              let body = data["body"], !body.isEmpty else {
            return nil
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Group by event_type (UX-44 — maps to Android setGroup)
        if let eventType = data["event_type"], !eventType.isEmpty {
            content.threadIdentifier = eventType
        } else {
            content.threadIdentifier = "odoo_messages"
        }

        // Store deep link URL in userInfo for tap handling
        if let actionUrl = data["odoo_action_url"] {
            content.userInfo["odoo_action_url"] = actionUrl
        }
        if let model = data["odoo_model"] {
            content.userInfo["odoo_model"] = model
        }
        if let resId = data["odoo_res_id"] {
            content.userInfo["odoo_res_id"] = resId
        }

        return content
    }

    /// Posts a local notification from FCM data.
    static func showNotification(data: [String: String]) {
        guard let content = buildContent(from: data) else { return }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Immediate delivery
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                #if DEBUG
                print("[NotificationService] Failed to show notification: \(error)")
                #endif
            }
        }
    }
}
