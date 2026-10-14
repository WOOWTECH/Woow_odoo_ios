import Foundation

/// The unlock screen's wrong-PIN line: "Wrong PIN. 4 attempts remaining" … "Wrong PIN. 1 attempt
/// remaining".
///
/// English picks the noun by count (1 attempt, 2 attempts), which one fixed `.strings` format cannot
/// do. `wrong_pin_%lld` therefore also lives in `Localizable.stringsdict` as a plural rule: English
/// has `one` + `other`, Chinese only `other` (no singular/plural distinction, same text as the
/// `.strings` entry, which stays as the plain fallback).
/// Ported from Android: PinScreen.kt (`<plurals name="wrong_pin_attempts_remaining">`).
///
/// The locale must follow the resource bundle, not the process locale. This matters for app-language
/// overrides and for tests that load one `.lproj` directly while the simulator uses another language.
func wrongPinMessage(remainingAttempts: Int, bundle: Bundle = .main) -> String {
    let format = NSLocalizedString(
        "wrong_pin_%lld",
        bundle: bundle,
        comment: "Wrong PIN, attempts remaining"
    )
    let bundleDirectory = bundle.bundleURL.lastPathComponent
    let languageIdentifier: String?
    if bundleDirectory.hasSuffix(".lproj") {
        languageIdentifier = String(bundleDirectory.dropLast(".lproj".count))
    } else {
        languageIdentifier = bundle.preferredLocalizations.first ?? bundle.developmentLocalization
    }
    let locale = languageIdentifier.map(Locale.init(identifier:)) ?? .current
    return String(format: format, locale: locale, arguments: [remainingAttempts])
}
