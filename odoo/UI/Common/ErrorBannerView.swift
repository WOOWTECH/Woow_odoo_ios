import SwiftUI

/// Reusable error message banner with red background.
/// Used across auth and login screens for consistent error display.
struct ErrorBannerView: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
