import Foundation

/// Decides whether Settings shows the Apporo "Push Registration" diagnostics
/// section (registration state + "acknowledgement is not delivery" caveat).
///
/// The section is a developer/QA aid, not a user feature: in a store build the
/// first Apporo release may ship before the customer server enables push, and
/// a permanent "Server has not configured Apporo push" row reads like a broken
/// app to users and App Review. So it is shown only in Debug-compiled builds
/// (Debug / ApporoDebug) and hidden in Release / ApporoRelease. The status
/// strings themselves are unchanged in all three localizations.
///
/// Pure decision in a caseless namespace so it is unit-testable without
/// rendering SwiftUI; the build flag is injected.
enum PushDiagnosticsVisibility {
    /// `true` only when this binary was compiled with the DEBUG condition.
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Apporo only (WOOW never had this section), only with an active account
    /// to report on, and only in a Debug-compiled build.
    static func isVisible(brand: AppBrand.Code, hasActiveAccount: Bool, isDebugBuild: Bool) -> Bool {
        brand == .apporo && hasActiveAccount && isDebugBuild
    }
}
