import Foundation
import WebKit

extension Notification.Name {
    /// Posted synchronously on the main actor right before an account's WebKit data is removed;
    /// `userInfo["accountId"]` names the account. The WebView coordinator showing that account
    /// retires its WebView (pi 0930, P2).
    static let accountWebViewMustRetire = Notification.Name("io.woowtech.odoo.accountWebViewMustRetire")
}

/// Removes one account's WebKit website data (cookies, storage, caches).
///
/// demo111 2026-09-29 (D1): logging out left `WebsiteDataStore/<accountId>/Cookies.binarycookies`
/// holding the account's `session_id`, surviving an app restart. Account removal now reads the
/// session ids that store holds (so they can be revoked server-side too), then removes the store.
@MainActor
protocol AccountWebDataCleaning: AnyObject {
    /// `session_id` values the account's WebKit store holds for `host` (the WebView may have been
    /// handed a newer session than the one in the Keychain).
    func sessionIds(forAccountId id: String, host: String) async -> [String]
    /// Removes the account's website data. On a per-account store: everything. On the shared
    /// default store (below iOS 17 / non-UUID ids): the `session_id` cookies for `host` whose value is
    /// in `sessionIds`; and, when no remaining account uses the same site, ALL of that site's data
    /// (pi 0930). While another account on the site remains, the rest of the site's data is shared
    /// with it and stays — a documented limitation of the shared store, not a full cleanup.
    /// `otherAccountHosts`: the server hosts of every account that remains after this removal.
    func removeWebData(forAccountId id: String, host: String, sessionIds: Set<String>,
                       otherAccountHosts: [String]) async
    /// Removes per-account stores whose identifier matches no account (left by an earlier build,
    /// or still in use by a live WebView when its account was removed).
    func pruneOrphanStores(keeping accountIds: Set<String>) async
}

@MainActor
final class AccountWebDataCleaner: AccountWebDataCleaning {

    /// Stops and drops the live WebView of an account before its data is removed.
    private let retireLiveWebView: @MainActor @Sendable (String) -> Void

    nonisolated init(retireLiveWebView: @escaping @MainActor @Sendable (String) -> Void = { accountId in
        NotificationCenter.default.post(name: .accountWebViewMustRetire, object: nil, userInfo: ["accountId": accountId])
    }) {
        self.retireLiveWebView = retireLiveWebView
    }

    func sessionIds(forAccountId id: String, host: String) async -> [String] {
        let cookies = await allCookies(in: OdooWebViewCoordinator.dataStore(forAccountId: id))
        return cookies.filter { $0.name == "session_id" && Self.matches($0, host: host) }.map(\.value)
    }

    func removeWebData(forAccountId id: String, host: String, sessionIds: Set<String>,
                       otherAccountHosts: [String]) async {
        // pi 0930 (P2): retire the account's live WebView first. While it lived it kept the store in
        // use — WebKit refused to delete it — and its page could write localStorage after the data
        // was removed, so the data survived until the next launch.
        retireLiveWebView(id)
        if #available(iOS 17.0, *), let uuid = UUID(uuidString: id) {
            do {
                // Scoped: WebKit also refuses to delete a store while any store object for it lives.
                let store = WKWebsiteDataStore(forIdentifier: uuid)
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
            await Self.deleteStore(uuid)
            return
        }
        let store = WKWebsiteDataStore.default()
        for cookie in await allCookies(in: store)
        where cookie.name == "session_id" && Self.matches(cookie, host: host) && sessionIds.contains(cookie.value) {
            await withCheckedContinuation { cont in store.httpCookieStore.delete(cookie) { cont.resume() } }
        }
        // pi 0930 (P2): WebKit groups data by site (registrable domain). A site no remaining account
        // uses is not shared any more — remove all of its data (storage, caches, other cookies).
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let unshared = await store.dataRecords(ofTypes: types).filter { record in
            Self.site(record.displayName, covers: host)
                && !otherAccountHosts.contains { Self.site(record.displayName, covers: $0) }
        }
        if !unshared.isEmpty {
            await store.removeData(ofTypes: types, for: unshared)
        }
    }

    /// Whether `host` belongs to the site WebKit names `displayName` (the site itself or a subdomain).
    private static func site(_ displayName: String, covers host: String) -> Bool {
        let d = displayName.lowercased(), h = host.lowercased()
        return !d.isEmpty && (h == d || h.hasSuffix("." + d))
    }

    func pruneOrphanStores(keeping accountIds: Set<String>) async {
        guard #available(iOS 17.0, *) else { return }
        // The class-level identifier fetch crashes (SIGSEGV in WTF::RunLoop::dispatch) when it is
        // the first WebKit call in the process — at launch no WebView exists yet. Instantiating a
        // store object first initializes WebKit's main run loop.
        _ = WKWebsiteDataStore.default()
        let keep = Set(accountIds.compactMap(UUID.init(uuidString:)))
        for identifier in await WKWebsiteDataStore.allDataStoreIdentifiers where !keep.contains(identifier) {
            let store = WKWebsiteDataStore(forIdentifier: identifier)
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
        }
    }

    /// Deletes a per-account store. A just-retired WebView can take a moment to release it; if
    /// something still holds it after the retries (about 2 s), its data is already removed and
    /// launch pruning deletes the empty store.
    @available(iOS 17.0, *)
    private static func deleteStore(_ id: UUID) async {
        for attempt in 1...20 {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return
            } catch {
                if attempt < 20 { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
        }
    }

    private func allCookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { cont in store.httpCookieStore.getAllCookies { cont.resume(returning: $0) } }
    }

    /// Cookie domain `host`, `.host`, or a parent domain the host belongs to.
    private static func matches(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        let h = host.lowercased(), d = domain.lowercased()
        return h == d || h.hasSuffix("." + d)
    }
}
