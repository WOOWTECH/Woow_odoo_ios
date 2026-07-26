import SwiftUI

/// Fail-closed screen when App Lock is ON but no in-app method is usable — RENDER ONLY. The
/// device-passcode evaluation lives in the `AuthViewModel` (via `BiometricAuthenticator`); this view
/// draws the state and forwards the unlock tap. It must NEVER fall through to the unlocked app.
struct AuthSetupRequiredView: View {
    @ObservedObject private var theme = WoowTheme.shared

    let prompting: Bool
    let error: String?
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(theme.primaryColor)

            Text(String(localized: "Unlock Required"))
                .font(.title2)
                .fontWeight(.bold)

            Text(String(localized: "No unlock method is available. Set up Face ID or a PIN in Settings, or unlock with your device passcode."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error {
                ErrorBannerView(message: error)
            }

            Spacer()

            Button {
                onUnlock()
            } label: {
                Text(String(localized: "Unlock with Passcode"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .disabled(prompting)

            Spacer().frame(height: 40)
        }
        .padding(32)
        .frame(maxWidth: 500)
    }
}

#Preview {
    AuthSetupRequiredView(prompting: false, error: nil, onUnlock: {})
}
