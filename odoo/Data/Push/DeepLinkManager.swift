import Foundation
import Combine

private let deepLinkUserDefaultsKey = "pending_deep_link_url"

/// Persists a pending deep link URL across the authentication flow.
/// Uses both in-memory storage (for warm navigation) and UserDefaults
/// (for cold-start survival when the app is killed before the link is consumed).
/// Direct port from Android: DeepLinkManager.kt
@MainActor
final class DeepLinkManager: ObservableObject {

    static let shared = DeepLinkManager()

    @Published private(set) var pendingUrl: String?

    private let defaults: UserDefaults

    /// Creates a DeepLinkManager.
    /// - Parameter defaults: The UserDefaults suite to persist pending URLs.
    ///   Defaults to `.standard`. Inject a custom suite in tests for isolation.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Cold-start recovery: restore URL persisted before the app was killed.
        if let persisted = defaults.string(forKey: deepLinkUserDefaultsKey) {
            pendingUrl = persisted
            defaults.removeObject(forKey: deepLinkUserDefaultsKey)
        }
    }

    /// Stores a URL to be navigated to after authentication completes.
    /// Writes to both in-memory and UserDefaults for cold-start survival.
    func setPending(_ url: String?) {
        pendingUrl = url
        if let url {
            defaults.set(url, forKey: deepLinkUserDefaultsKey)
        } else {
            defaults.removeObject(forKey: deepLinkUserDefaultsKey)
        }
    }

    /// Returns and clears the pending URL. Returns nil if no URL is pending.
    /// Clears both in-memory and UserDefaults storage.
    func consume() -> String? {
        let current = pendingUrl
        pendingUrl = nil
        defaults.removeObject(forKey: deepLinkUserDefaultsKey)
        return current
    }
}
