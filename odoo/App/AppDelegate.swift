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
        #if DEBUG
        processTestLaunchArguments()
        #endif

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

        // Register notification category with hidden previews placeholder (G7).
        // When the user has "Show Previews: When Unlocked" in iOS Settings,
        // the lock screen displays this placeholder instead of the full message body.
        let odooCategory = UNNotificationCategory(
            identifier: "odoo_message",
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "New Odoo notification"
        )
        UNUserNotificationCenter.current().setNotificationCategories([odooCategory])

        application.registerForRemoteNotifications()

        return true
    }

    // MARK: - XCUITest Debug Hooks

    /// Reads XCUITest launch arguments and configures a known app state for deterministic tests.
    ///
    /// Each argument is guarded by `#if DEBUG` at the call site. This method must only be
    /// called from within a `#if DEBUG` block. The hooks are:
    ///
    /// - `-ResetAppState YES`: Clears all Keychain entries and Core Data accounts so each
    ///   test that requires a clean slate starts from first-launch state.
    /// - `-SetTestPIN <digits>`: Hashes and stores a known PIN via `SettingsRepository`
    ///   so PIN-unlock tests can enter a deterministic value without navigating Settings.
    /// - `-AppLockEnabled YES`: Forces `appLockEnabled = true` in `SettingsRepository`
    ///   so biometric/PIN gate tests do not need to toggle the Settings switch.
    #if DEBUG
    private func processTestLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments

        if args.contains("-ResetAppState") {
            clearAllAppState()
        }

        // Parse paired arguments: the value follows the flag name in the args array.
        let settingsRepo = SettingsRepository()

        if let pinIndex = args.firstIndex(of: "-SetTestPIN"),
           args.indices.contains(pinIndex + 1) {
            let pin = args[pinIndex + 1]
            _ = settingsRepo.setPin(pin)
            print("[TestHook] SetTestPIN applied: \(pin.count)-digit PIN stored")
        }

        if let lockIndex = args.firstIndex(of: "-AppLockEnabled"),
           args.indices.contains(lockIndex + 1),
           args[lockIndex + 1].uppercased() == "YES" {
            settingsRepo.setAppLock(true)
            print("[TestHook] AppLockEnabled applied: app lock is ON")
        }
    }

    /// Wipes Keychain settings and Core Data accounts to produce first-launch state.
    /// Mirrors the data cleared by `AccountRepository.logout` for every account,
    /// plus removes app settings so PIN/lock state is reset to defaults.
    private func clearAllAppState() {
        // Clear app settings (includes PIN hash, app lock flag, theme, etc.)
        SecureStorage.shared.saveSettings(AppSettings())

        // Clear Core Data accounts — delete the persistent store and recreate it
        let persistence = PersistenceController.shared
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchAllRequest()
        if let entities = try? context.fetch(request) {
            for entity in entities {
                let serverUrl = entity.serverUrl ?? ""
                let username = entity.username ?? ""
                SecureStorage.shared.deletePassword(serverUrl: serverUrl, username: username)
                SecureStorage.shared.deleteSessionId(serverUrl: serverUrl, username: username)
                context.delete(entity)
            }
            try? context.save()
        }

        // Clear HTTPCookieStorage so no session cookies remain from prior runs
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        print("[TestHook] ResetAppState applied: Core Data, Keychain, and cookies cleared")
    }
    #endif

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
    ///
    /// Reads the active account's server host from Core Data to pass into the validator.
    /// The `hasPrefix("/web")` short-circuit is intentionally absent — validation must always
    /// run through `DeepLinkValidator.isValid` to enforce the strict path regex and prevent
    /// path-traversal or host-override payloads from bypassing validation.
    @MainActor
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let actionUrl = userInfo["odoo_action_url"] as? String else { return }
        let serverHost = AccountRepository().getActiveAccount()?.serverHost ?? ""
        if DeepLinkValidator.isValid(url: actionUrl, serverHost: serverHost) {
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
