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
/// `localizedStringWithFormat` on the bundle's looked-up format is what applies the plural rule;
/// the previous `String(format:)` over the plain `.strings` entry always produced "attempts".
func wrongPinMessage(remainingAttempts: Int, bundle: Bundle = .main) -> String {
    String.localizedStringWithFormat(
        NSLocalizedString("wrong_pin_%lld", bundle: bundle, comment: "Wrong PIN, attempts remaining"),
        remainingAttempts
    )
}
