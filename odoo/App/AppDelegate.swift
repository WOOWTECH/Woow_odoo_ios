import UIKit
import UserNotifications

// Firebase import — uncomment after adding Firebase SDK via SPM:
// import FirebaseCore
// import FirebaseMessaging

/// App delegate handling push notifications and Firebase setup.
/// Ported from Android: WoowFcmService.kt + WoowOdooApp.kt
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Firebase setup — uncomment after adding Firebase SDK:
        // FirebaseApp.configure()
        // Messaging.messaging().delegate = self

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
        // Forward to Firebase — uncomment after adding Firebase SDK:
        // Messaging.messaging().apnsToken = deviceToken
        #if DEBUG
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[AppDelegate] APNs token: \(token)")
        #endif
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

        // Extract deep link URL from notification data
        if let actionUrl = userInfo["odoo_action_url"] as? String {
            let serverHost = "" // Will be set from active account
            if DeepLinkValidator.isValid(url: actionUrl, serverHost: serverHost) || actionUrl.hasPrefix("/web") {
                DeepLinkManager.shared.setPending(actionUrl)
            }
        }

        completionHandler()
    }
}

// MARK: - Firebase MessagingDelegate
// Uncomment after adding Firebase SDK via SPM:
/*
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
*/
