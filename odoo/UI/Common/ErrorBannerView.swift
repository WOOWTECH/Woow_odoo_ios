import SwiftUI

/// Reusable error message banner with red background.
/// Used across auth and login screens for consistent error display.
struct ErrorBannerView: View {
    let message: String

    /// Opaque fill behind the white message text, the same in light and dark mode.
    /// The previous `Color.red.opacity(0.85)` gave white text only about 3.1:1 in light mode
    /// (system red #FF3B30 at 85% over white) — below WCAG AA 4.5:1. #D70015 is iOS's own
    /// increased-contrast system red for light mode; white on it is 5.38:1, and because the fill
    /// is opaque the ratio does not depend on what is behind the banner.
    static let backgroundHex = "#D70015"
    static let background = Color(hex: backgroundHex)

    var body: some View {
        Text(message)
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Self.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
