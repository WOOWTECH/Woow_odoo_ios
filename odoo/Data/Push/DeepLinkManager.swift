import Foundation
import Combine

/// UserDefaults keys. The URL key is unchanged from the original single-account format so a
/// link persisted by an older build still cold-starts; the account/time keys are additive.
private let deepLinkUrlKey = "pending_deep_link_url"
private let deepLinkAccountKey = "pending_deep_link_account_id"
private let deepLinkCreatedAtKey = "pending_deep_link_created_at"

/// How long a pending deep link stays valid after being set. A notification tap that is
/// never consumed (e.g. the target account never finishes loading) is discarded after
/// this window so a stale link can never fire against a later, unrelated session.
private let pendingDeepLinkTTL: TimeInterval = 5 * 60

/// A deep link waiting to be applied, bound to the account that must handle it.
///
/// Binding is the cross-tenant safety mechanism: the link is only ever applied to the
/// account whose notification produced it. `createdAt` drives the TTL.
struct PendingDeepLink: Equatable {
    let url: String
    let accountId: String
    let createdAt: Date

    /// True when the link is older than `pendingDeepLinkTTL` relative to `now`.
    func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > pendingDeepLinkTTL
    }
}

/// Persists a pending deep link across the authentication / account-switch flow.
///
/// The link is **bound to a target account id** so it is only ever applied to the account
/// that produced the originating notification — never another tenant's WebView. Storage is
/// both in-memory (warm navigation) and `UserDefaults` (cold-start survival when the app is
/// killed before the link is consumed). Single-consume + TTL + drop-on-foreign-login prevent
/// a stale link from firing against the wrong session.
/// Direct port from Android: DeepLinkManager.kt
@MainActor
final class DeepLinkManager: ObservableObject {

    static let shared = DeepLinkManager()

    /// The currently pending link, if any and not expired. Observed by `MainViewModel`.
    @Published private(set) var pending: PendingDeepLink?

    /// Back-compat convenience: the pending URL string, ignoring binding. Used by the
    /// legacy cold-start consume path and existing tests. Prefer `pending` / `consume(for:)`.
    var pendingUrl: String? { pending?.url }

    private let defaults: UserDefaults

    /// Creates a DeepLinkManager.
    /// - Parameter defaults: The UserDefaults suite to persist pending links.
    ///   Defaults to `.standard`. Inject a custom suite in tests for isolation.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Cold-start recovery: restore a link persisted before the app was killed, then
        // clear the disk copy immediately so it can never replay on a later launch.
        if let url = defaults.string(forKey: deepLinkUrlKey) {
            let accountId = defaults.string(forKey: deepLinkAccountKey) ?? ""
            // A link written by an older build has no timestamp — treat it as fresh.
            let createdAt = (defaults.object(forKey: deepLinkCreatedAtKey) as? Date) ?? Date()
            let restored = PendingDeepLink(url: url, accountId: accountId, createdAt: createdAt)
            clear()
            if !restored.isExpired() {
                pending = restored
            }
        } else {
            clear()
        }
    }

    /// Stores a URL to be navigated to after the target account's WebView finishes loading,
    /// bound to `accountId`. Writes to both in-memory and UserDefaults for cold-start survival.
    func setPending(_ url: String, accountId: String) {
        let link = PendingDeepLink(url: url, accountId: accountId, createdAt: Date())
        pending = link
        defaults.set(url, forKey: deepLinkUrlKey)
        defaults.set(accountId, forKey: deepLinkAccountKey)
        defaults.set(link.createdAt, forKey: deepLinkCreatedAtKey)
    }

    /// Legacy setter — binds the URL to an empty account id (single-account back-compat).
    /// Passing `nil` clears the pending link.
    func setPending(_ url: String?) {
        if let url {
            setPending(url, accountId: "")
        } else {
            clear()
        }
    }

    /// Returns and clears the pending URL **only if** it is bound to `accountId` (or was
    /// stored unbound, i.e. legacy single-account) and has not expired. Returns `nil`
    /// otherwise, leaving any foreign-bound link untouched so it can still reach its own
    /// account. This is the load-gated, single-consume entry point.
    func consume(for accountId: String) -> String? {
        guard let link = pending else { return nil }
        if link.isExpired() {
            clear()
            return nil
        }
        // An empty stored accountId is a legacy/unbound link — any account may take it.
        guard link.accountId.isEmpty || link.accountId == accountId else { return nil }
        clear()
        return link.url
    }

    /// Returns and clears the pending URL regardless of binding. Retained for the legacy
    /// cold-start path and existing callers. Prefer `consume(for:)`.
    func consume() -> String? {
        let current = pending?.url
        clear()
        return current
    }

    /// Drops the pending link if it is bound to an account **other** than `accountId`.
    ///
    /// Called when an account logs in: a link that was waiting for a different account must
    /// never survive into an unrelated session. A matching or unbound link is preserved.
    func invalidateIfNotTarget(accountId: String) {
        guard let link = pending else { return }
        if !link.accountId.isEmpty, link.accountId != accountId {
            clear()
        }
    }

    private func clear() {
        pending = nil
        defaults.removeObject(forKey: deepLinkUrlKey)
        defaults.removeObject(forKey: deepLinkAccountKey)
        defaults.removeObject(forKey: deepLinkCreatedAtKey)
    }
}
