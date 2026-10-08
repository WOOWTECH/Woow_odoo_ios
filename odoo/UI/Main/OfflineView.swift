import SwiftUI

/// The app's own offline screen, shown over the WebView when the current account's page could not
/// be loaded (W2-4 L1). Brand-coloured retry button, localized copy, and deliberately no server
/// address, URL or error code.
struct OfflineView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(String(localized: "offline_title"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(String(localized: "offline_message"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onRetry) {
                Text(String(localized: "offline_retry"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: 280)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(WoowTheme.fixedBrandButtonColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("offline-retry")
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-screen")
    }
}

#Preview {
    OfflineView(onRetry: {})
}
