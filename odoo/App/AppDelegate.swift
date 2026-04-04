import UIKit
import UserNotifications

#if canImport(FirebaseCore)
import FirebaseCore
import FirebaseMessaging
#endif

/// App delegate handling push notifications and Firebase setup.
/// Ported from Android: WoowFcmService.kt + WoowOdooApp.kt
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if canImport(FirebaseCore)
        FirebaseApp.configure()
        Messaging.messaging().delegate = self
        #endif

        // Request notification permission
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            #if DEBUG
            print("[AppDelegate] Notification permission: \(granted)")
            #endif
        }
        application.registerForRemoteNotifications()

        return true
    }

    // MARK: - Remote Notification Token

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        #if canImport(FirebaseMessaging)
        Messaging.messaging().apnsToken = deviceToken
        #endif
        #if DEBUG
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[AppDelegate] APNs token: \(token)")
        #endif
    }

    // MARK: - Remote Notification Handler
    // Handles both data-only and notification+data messages from FCM.
    // When server sends notification+apns payload (iOS), the system displays it
    // automatically. This handler only creates a local notification for data-only
    // messages (fallback for Android-style payloads).

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        #if canImport(FirebaseMessaging)
        Messaging.messaging().appDidReceiveMessage(userInfo)
        #endif

        // If aps.alert exists, iOS already displayed this notification — skip local
        // notification to prevent duplicates. See docs/2026-04-04-ios-notification-fix.md
        let aps = userInfo["aps"] as? [String: Any]
        let hasSystemAlert = aps?["alert"] != nil

        #if DEBUG
        let dataKeys = userInfo.keys.compactMap { $0 as? String }.sorted()
        print("[AppDelegate] Received remote notification (keys: \(dataKeys), systemAlert: \(hasSystemAlert))")
        #endif

        if hasSystemAlert {
            // System already showed the notification — just acknowledge
            completionHandler(.newData)
            return
        }

        // Data-only message — create local notification ourselves
        var data: [String: String] = [:]
        for (key, value) in userInfo {
            if let k = key as? String {
                data[k] = "\(value)"
            }
        }

        if data["title"] != nil || data["body"] != nil {
            NotificationService.showNotification(data: data)
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }

    // MARK: - Notification Display (Foreground)

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner even when app is in foreground (UX-46)
        completionHandler([.banner, .sound, .badge])
    }

    // MARK: - Notification Tap

    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        handleNotificationTap(userInfo: userInfo)
        completionHandler()
    }

    /// Extracted for testability — processes notification tap deep link.
    @MainActor
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let actionUrl = userInfo["odoo_action_url"] as? String else { return }
        if actionUrl.hasPrefix("/web") || DeepLinkValidator.isValid(url: actionUrl, serverHost: "") {
            DeepLinkManager.shared.setPending(actionUrl)
        }
    }
}

// MARK: - Firebase MessagingDelegate

#if canImport(FirebaseMessaging)
extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        #if DEBUG
        print("[AppDelegate] FCM token: \(token)")
        #endif

        Task {
            let repo = PushTokenRepository()
            await repo.registerTokenWithAllAccounts(token)
        }
    }
}
#endif
