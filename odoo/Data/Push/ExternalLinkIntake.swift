import Foundation

/// Routes an external `<brand scheme>://open?url=<encoded>` link into the pending deep link, which
/// the WebView then applies load-gated. Extracted from `odooApp.handleIncomingURL` so it is testable.
///
/// F3 (0930): the link is validated against, and BOUND to, the account active when it arrives
/// (unbound links used to follow whichever account was active at apply time); with no signed-in
/// account it is ignored. `MainViewModel` drops a link bound to another account on every switch.
@MainActor
enum ExternalLinkIntake {

    /// Validates `url`'s `url` parameter against the active account and queues it.
    /// Returns true when a link was queued, false when the URL is ignored.
    @discardableResult
    static func accept(_ url: URL, brand: AppBrand = .current, activeAccount: OdooAccount?,
                       manager: DeepLinkManager) -> Bool {
        guard brand.acceptsScheme(url.scheme) else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return false
        }
        // F3 (0930, Android `ExternalLinkIntake` parity): nobody signed in → nothing to apply it to.
        guard let active = activeAccount else { return false }
        guard DeepLinkValidator.isValid(url: urlParam, serverHost: active.serverHost) else { return false }
        // Bound to the account active on arrival, so a later switch can never apply it elsewhere.
        manager.setPending(urlParam, accountId: active.id)
        return true
    }
}
