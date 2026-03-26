import Foundation
import Combine

/// Persists a pending deep link URL across the authentication flow.
/// Direct port from Android: DeepLinkManager.kt
@MainActor
final class DeepLinkManager: ObservableObject {

    static let shared = DeepLinkManager()

    @Published private(set) var pendingUrl: String?

    /// Stores a URL to be navigated to after authentication completes.
    func setPending(_ url: String?) {
        pendingUrl = url
    }

    /// Returns and clears the pending URL. Returns nil if no URL is pending.
    func consume() -> String? {
        let current = pendingUrl
        pendingUrl = nil
        return current
    }
}
