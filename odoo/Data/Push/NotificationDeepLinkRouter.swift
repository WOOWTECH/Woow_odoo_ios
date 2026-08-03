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

    /// ACCOUNT-scoped routing key (P2-9). Preferred over ``tenantIdKey`` when present.
    static let deviceIdKey = "odoo_device_id"

    /// Why a notification tap did not produce a navigation.
    enum DropReason: Equatable {
        /// No `odoo_action_url` in the payload — nothing to navigate to.
        case noActionUrl
        /// The action URL failed `DeepLinkValidator` (external host, traversal, etc.).
        case invalidUrl
        /// A tenant id was present but matched no local account. NEVER fall back to A.
        case unresolvedTenant
        /// A tenant id matched MORE THAN ONE local account, so it cannot identify one
        /// (story 10-1, P2-9).
        ///
        /// Distinct from `unresolvedTenant` on purpose: "two of our boxes were deployed
        /// with the same database name" and "this push is for an account we do not have"
        /// are different operational problems with different fixes, and an operator
        /// reading logs must be able to tell them apart. Collapsing them would hide a
        /// mis-provisioning behind what looks like ordinary noise.
        case ambiguousTenant
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
    ///   - resolveTenant: Maps an opaque tenant id to a local account, or `nil` — which now means
    ///     EITHER no match OR more than one (the repository refuses to pick).
    ///   - isAmbiguousTenant: True when the id matches several accounts.
    ///   - isTenantCandidate: `(accountId, tenantId)` → true when that account is one of the
    ///     matches. Consulted ONLY on the ambiguous path, and only to decide whether the
    ///     already-active account may keep the link — it can never cause a SWITCH, so it cannot
    ///     produce a cross-tenant navigation.
    ///   - activeAccount: The currently active account, or `nil`.
    static func decide(
        userInfo: [AnyHashable: Any],
        resolveDevice: (String) -> OdooAccount? = { _ in nil },
        resolveTenant: (String) -> OdooAccount?,
        isAmbiguousTenant: (String) -> Bool = { _ in false },
        isTenantCandidate: (String, String) -> Bool = { _, _ in false },
        activeAccount: OdooAccount?
    ) -> Decision {
        guard let actionUrl = userInfo[actionUrlKey] as? String else {
            return .drop(.noActionUrl)
        }

        // P2-9 root cause: prefer the ACCOUNT-scoped key when the server sent one.
        //
        // A tenant id names a TENANT — the server resolves it to the database name — so two
        // users on ONE database share it unavoidably and it cannot select between them. A
        // device row id is unique per (fcm_token, user_id) by construction.
        //
        // A device id that matches NOTHING drops rather than falling back to the tenant id:
        // falling back would re-introduce exactly the guess this key removes, and an
        // unmatched id means our stored row is stale, not that the server failed to
        // identify the account.
        let deviceId = (userInfo[deviceIdKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !deviceId.isEmpty {
            guard let target = resolveDevice(deviceId) else {
                return .drop(.unresolvedTenant)
            }
            guard DeepLinkValidator.isValid(url: actionUrl, serverHost: target.serverHost) else {
                return .drop(.invalidUrl)
            }
            return .switchAndRoute(accountId: target.id, url: actionUrl)
        }

        let tenantId = (userInfo[tenantIdKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !tenantId.isEmpty {
            // Multi-account routing path.
            // `resolveTenant` returns nil for BOTH "no match" and "more than one match" —
            // the repository refuses ambiguity rather than picking a row. `isAmbiguous`
            // separates the two so the drop reason is actionable.
            guard let target = resolveTenant(tenantId) else {
                guard isAmbiguousTenant(tenantId) else { return .drop(.unresolvedTenant) }

                // Ambiguous. Prefer the ACTIVE account when it is one of the candidates,
                // rather than dropping outright.
                //
                // Take the premise seriously: `odoo_tenant_id` is the database name and
                // §4.3 ships every STB box with the same POSTGRES_DB, so collision is the
                // DEFAULT deployment, not the exception. A bare drop therefore makes every
                // notification tap a silent no-op on such an install — the notification
                // dismisses, nothing opens, no message, until someone reads os_log. That
                // is a worse day-to-day experience than the bug.
                //
                // Routing to the active account performs NO account switch, so it cannot
                // leak across tenants — it is exactly the old-plugin `useActive` path this
                // router already treats as safe. It only ever applies when the active
                // account is genuinely a candidate; otherwise we still drop.
                if let active = activeAccount,
                   isTenantCandidate(active.id, tenantId),
                   DeepLinkValidator.isValid(url: actionUrl, serverHost: active.serverHost) {
                    return .useActive(accountId: active.id, url: actionUrl)
                }
                return .drop(.ambiguousTenant)
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
