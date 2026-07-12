import Foundation

/// Pure decision logic for routing a tapped push notification to the correct account.
///
/// Extracted from `AppDelegate` so the cross-tenant routing rules can be unit-tested
/// without a live `UIApplication`, Core Data stack, or WebView. The router itself performs
/// no side effects — it reads the payload plus a tenant-id resolver and returns a
/// `Decision` that the caller executes.
enum NotificationDeepLinkRouter {

    /// Payload key carrying the deep-link path (e.g. `/web#active_id=mail.channel_7`).
    static let actionUrlKey = "odoo_action_url"
    /// Payload key carrying the opaque tenant id (the multi-account routing key).
    static let tenantIdKey = "odoo_tenant_id"

    /// Why a notification tap did not produce a navigation.
    enum DropReason: Equatable {
        /// No `odoo_action_url` in the payload — nothing to navigate to.
        case noActionUrl
        /// The action URL failed `DeepLinkValidator` (external host, traversal, etc.).
        case invalidUrl
        /// A tenant id was present but matched no local account. NEVER fall back to A.
        case unresolvedTenant
    }

    /// The outcome of evaluating a notification tap.
    enum Decision: Equatable {
        /// A tenant id resolved to `accountId`: switch to it, then apply `url` bound to it.
        case switchAndRoute(accountId: String, url: String)
        /// No tenant id (old plugin): keep the active account and apply `url` bound to it.
        /// `accountId` is the active account's id, or empty when no account is active
        /// (preserves legacy behaviour for relative `/web` links).
        case useActive(accountId: String, url: String)
        /// Do nothing — the active account must be left untouched.
        case drop(DropReason)
    }

    /// Decides how to handle a notification tap.
    ///
    /// Rules (frozen, P0 cross-tenant isolation):
    /// - Missing `odoo_action_url` → drop.
    /// - Tenant id present + resolves to an account → validate against THAT account's host,
    ///   then `switchAndRoute`. Present but unresolved → `drop(.unresolvedTenant)`; never A.
    /// - Tenant id absent (old plugin) → validate against the active account's host and
    ///   `useActive` (current behaviour).
    ///
    /// - Parameters:
    ///   - userInfo: The raw notification payload.
    ///   - resolveTenant: Maps an opaque tenant id to a local account, or `nil`.
    ///   - activeAccount: The currently active account, or `nil`.
    static func decide(
        userInfo: [AnyHashable: Any],
        resolveTenant: (String) -> OdooAccount?,
        activeAccount: OdooAccount?
    ) -> Decision {
        guard let actionUrl = userInfo[actionUrlKey] as? String else {
            return .drop(.noActionUrl)
        }

        let tenantId = (userInfo[tenantIdKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !tenantId.isEmpty {
            // Multi-account routing path.
            guard let target = resolveTenant(tenantId) else {
                return .drop(.unresolvedTenant)
            }
            guard DeepLinkValidator.isValid(url: actionUrl, serverHost: target.serverHost) else {
                return .drop(.invalidUrl)
            }
            return .switchAndRoute(accountId: target.id, url: actionUrl)
        }

        // Old-plugin fallback: validate against the active account (host may be empty for
        // relative /web paths, which the validator accepts regardless of host).
        let serverHost = activeAccount?.serverHost ?? ""
        guard DeepLinkValidator.isValid(url: actionUrl, serverHost: serverHost) else {
            return .drop(.invalidUrl)
        }
        return .useActive(accountId: activeAccount?.id ?? "", url: actionUrl)
    }
}
